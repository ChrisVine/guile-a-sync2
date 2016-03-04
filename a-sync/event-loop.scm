;; Copyright Chris Vine 2014 and 2016

;; This library is free software; you can redistribute it and/or
;; modify it under the terms of the GNU Lesser General Public
;; License as published by the Free Software Foundation; either
;; version 3 of the License, or (at your option) any later version.
;; 
;; This library is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; Lesser General Public License for more details.
;; 
;; You should have received a copy of the GNU Lesser General Public
;; License along with this library; if not, write to the Free Software
;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

(define-module (a-sync event-loop)
  #:use-module (ice-9 q)               ;; for make-q, etc
  #:use-module (srfi srfi-1)           ;; for reduce, delete!, alist-delete!, delete-duplicates and assoc
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 threads)         ;; for with-mutex and call-with-new-thread
  #:use-module (a-sync monotonic-time) ;; for get-time
  #:export (make-event-loop
	    event-loop-run!
	    event-loop-add-read-watch!
	    event-loop-add-write-watch!
	    event-loop-remove-watch!
	    event-loop-block!
	    event-loop-quit!
	    event-post!
	    timeout-post!
	    timeout-remove!
	    event-loop?
	    await-task!
	    await-task-in-thread!
	    await-timeout!
	    a-sync-read-watch!
	    a-sync-write-watch!
	    await-getline!))


(define-record-type <event-loop>
  (_make-event-loop mutex q done event-in event-out read-files read-files-actions
                    write-files write-files-actions timeouts current-timeout block)
  event-loop?
  (mutex _mutex-get)
  (q _q-get)
  (done _done-get _done-set!)
  (event-in _event-in-get _event-in-set!)
  (event-out _event-out-get _event-out-set!)
  (read-files _read-files-get _read-files-set!)
  (read-files-actions _read-files-actions-get _read-files-actions-set!)
  (write-files _write-files-get _write-files-set!)
  (write-files-actions _write-files-actions-get _write-files-actions-set!)
  (timeouts _timeouts-get _timeouts-set!)
  (current-timeout _current-timeout-get _current-timeout-set!)
  (block _block-get _block-set!))
  
(define (make-event-loop)
  (let* ((event-pipe (pipe))
	 (in (car event-pipe))
	 (out (cdr event-pipe)))
    ;; the write end of the pipe needs to be set non-blocking so that
    ;; if the pipe fills and the event loop thread is also putting a
    ;; new event in the queue, an exception is thrown rather than a
    ;; deadlock arising
    (fcntl out F_SETFL (logior O_NONBLOCK
			       (fcntl out F_GETFL)))
    (_make-event-loop (make-mutex)
		      (make-q)
		      #f
		      in
		      out
		      '()
		      '()
		      '()
		      '()
		      '()
		      #f
		      #f)))

;; timeouts are kept as an unsorted list of timeout items.  Each
;; timeout item is a vector of four elements.  First, an absolute time
;; pair (say as generated by _get-abstime) representing the time it is
;; next due to fire; second, a gensym value representing its tag;
;; third, the timeout value in milliseconds from which it was
;; generated (so it can be used again if it is a repeating timeout);
;; and fourth, a callback thunk representing the action to be executed
;; when the timeout is due.  This procedure finds the next timeout
;; item due to fire, or #f if the list passed in is empty.
(define (_next-timeout timeouts)
  (reduce (lambda (elt previous)
	    (if (< (_time-remaining (vector-ref elt 0))
		   (_time-remaining (vector-ref previous 0)))
		elt
		previous))
	  #f
	  timeouts))

;; for an absolute time pair (secs . usecs), say as generated by
;; _get-abstime, this returns the number of seconds remaining to
;; current time as a real number.  If the absolute time is in the
;; past, it returns a negative number: this is useful behaviour as it
;; will help the _next-timeout procedure pick the oldest timeout
;; amongst any which have already expired.  However, normalize a
;; negative value to 0 before passing it to select.
(define (_time-remaining abstime)
  (let ((curr (get-time)))
   (let ((secs (- (car abstime) (car curr)))
	  (usecs (- (cdr abstime) (cdr curr))))
      (+ (exact->inexact secs) (/ (exact->inexact usecs) 1000000)))))

;; takes a timeout value in milliseconds and returns a (secs . usecs)
;; pair representing current time plus the timeout value as an
;; absolute time
(define (_get-abstime msecs)
  (let* ((curr (get-time))
	 (usec-tmp (round (+ (* msecs 1000) (cdr curr)))))
    (let ((secs (+ (car curr) (quotient usec-tmp 1000000)))
	  (usecs (remainder usec-tmp 1000000)))
    (cons secs usecs))))

(define (_process-timeouts el)
  ;; we don't need any mutexes here as we only access the timeouts and
  ;; current-timeout fields of an event loop object, and any
  ;; individual timeout item vectors, in the event loop thread
  (let ((current-timeout (_current-timeout-get el)))
    (when (and current-timeout
	       (<= (_time-remaining (vector-ref current-timeout 0)) 0))
      (if ((vector-ref current-timeout 3))
	  (vector-set! current-timeout 0
		       (_get-abstime (vector-ref current-timeout 2)))
	  (_timeouts-set! el (_filter-timeout (_timeouts-get el) (vector-ref current-timeout 1))))
      (_current-timeout-set! el (_next-timeout (_timeouts-get el))))))

;; This returns a list of timeouts, with the tagged timeout removed
;; from the timeout list passed in
(define (_filter-timeout timeouts tag)
  (let loop ((remaining timeouts)
	     (checked '()))
    (if (null? remaining)
	(begin
	  ;; it is probably too extreme to error here if the user
	  ;; requests to remove a timeout which no longer exists
	  (simple-format (current-error-port)
			 "Warning: timeout tag ~A not found in timeouts list in procedure _filter-timeout\n"
			 tag)
	  (force-output (current-error-port))
	  timeouts)
	(let ((first (car remaining)))
	  (if (eq? (vector-ref first 1) tag)
	      (append (reverse checked) (cdr remaining))
	      (loop (cdr remaining) (cons first checked)))))))

;; for the purposes of the event loop, two files compare equal if
;; their file descriptors are the same, even if one is a port and one
;; is a file descriptor (or both are a file)
(define (_file-equal? file1 file2)
  (let ((fd1 (if (port? file1) (fileno file1) file1))
	(fd2 (if (port? file2) (fileno file2) file2)))
    (= fd1 fd2)))

;; we don't need any mutexes here as we only access any of the
;; read-files, read-files-actions, write-files and write-files-actions
;; fields in the event loop thread.  This removes a given file watch
;; and its action from an event loop object.  If there is both a read
;; and write watch for the same file, both are removed.  A file
;; descriptor and a port with the same underlying file descriptor, or
;; two ports with the same underlying file descriptor, compare equal
;; for the purposes of removal.
(define (_remove-watch-impl! el file)
  (_read-files-set! el (delete! file (_read-files-get el) _file-equal?))
  (_write-files-set! el (delete! file (_write-files-get el) _file-equal?))
  (_read-files-actions-set! el (alist-delete! file (_read-files-actions-get el) _file-equal?))
  (_write-files-actions-set! el (alist-delete! file (_write-files-actions-get el) _file-equal?)))

;; the event loop runs in the thread which calls this procedure.  If
;; this is different from the thread which called make-event-loop,
;; external synchronization is required to ensure visibility.  Where
;; event-loop-quit! has been called, this procedure may be called
;; again to restart the same event loop.  If a callback throws, or
;; something else throws in the implementation, then this procedure
;; will return and it will be as if event-loop-quit! had been called.
(define (event-loop-run! el)
  (define mutex (_mutex-get el))
  (define q (_q-get el))
  (define event-in (_event-in-get el))
  (define event-fd (fileno event-in))

  (catch
   #t
   (lambda ()
     ;; we don't need to use the mutex in this procedure except in
     ;; relation to q, _done-get and _block-get, as we only access the
     ;; current-timeout field of an event loop object, any individual
     ;; timeout item vectors, and any of the read-files,
     ;; read-files-actions, write-files and write-files-actions fields
     ;; in the event loop thread
     (let loop1 ()
       (_process-timeouts el)
       (when (not (and (null? (_read-files-get el))
		       (null? (_write-files-get el))
		       (null? (_timeouts-get el))
		       (with-mutex mutex (and (q-empty? q)
					      (not (_block-get el))))))
         ;; we provide local versions in order to take a consistent view
         ;; on each run, since we might remove items from the lists after
         ;; executing the callbacks
         (let ((read-files (_read-files-get el))
	       (read-files-actions (_read-files-actions-get el))
	       (write-files (_write-files-get el))
	       (write-files-actions (_write-files-actions-get el))
	       (current-timeout (_current-timeout-get el)))
	   (let ((res (catch 'system-error
		        (lambda ()
			  (select (cons event-fd read-files)
				  write-files
				  (delete-duplicates (append read-files write-files) _file-equal?)
				  (and current-timeout
				       (let ((secs (_time-remaining (vector-ref current-timeout 0))))
					 (if (< secs 0) 0 secs)))))
			(lambda args
			  (if (= EINTR (system-error-errno args))
			      '(() () ())
			      (apply throw args))))))
	     (for-each (lambda (elt)
			 (let ((action
				(let ((item (assoc elt read-files-actions _file-equal?)))
				  (if item (cdr item) #f))))
			   (if action
			       (when (not (action 'in))
				 (_remove-watch-impl! el elt))
			       (error "No action in event loop for read file: " elt))))
		       (delv event-fd (car res)))
	     (for-each (lambda (elt)
			 (let ((action
				(let ((item (assoc elt write-files-actions _file-equal?)))
				  (if item (cdr item) #f))))
			   (if action
			       (when (not (action 'out))
			         (_remove-watch-impl! el elt))
			       (error "No action in event loop for write file: " elt))))
		       (cadr res))
	     (for-each (lambda (elt)
			 (let ((action
				(let ((item (assoc elt (append read-files-actions write-files-actions) _file-equal?)))
				  (if item (cdr item) #f))))
			   (if action
			       (when (not (action 'excpt))
				 (_remove-watch-impl! el elt))
			       (error "No action in event loop for file: " elt))))
		       (caddr res))
	     (when (memv event-fd (car res))
	       (let loop2 ()
		 (let ((c (read-char event-in)))
		   (if (eof-object? c)
		       (with-mutex mutex (_done-set! el #t))
		       (case c
			 ((#\x)
			  (let loop3 ()
			    ;; the strategy is to exhaust the entire
			    ;; event queue when #\x is in the pipe
			    ;; buffer.  This eliminates any concerns
			    ;; that events might go missing if the
			    ;; pipe fills up.
			    (let ((action (with-mutex mutex
					    (if (q-empty? q) #f (deq! q)))))
			      (when action
			        (action)
				(when (not (with-mutex mutex (_done-get el)))
			          (loop3)))))
			  (when (and (char-ready? event-in)
				     (not (with-mutex mutex (_done-get el))))
			    (loop2)))
			 (else
			  (error "Invalid character in event pipe: " c))))))))
	   (if (not (with-mutex mutex (_done-get el)))
	       (loop1)
	       ;; clear out any stale events before returning and
	       ;; unblocking
	       (_event-loop-reset! el))))))
   (lambda args
     ;; something threw, probably a callback.  Put the event loop in a
     ;; valid state and rethrow
     (_event-loop-reset! el)
     (apply throw args))))
   
;; This procedure is only called in the event loop thread, by
;; event-loop-run!  The only things requiring protection by a mutex
;; are the q, done-set and event-out fields of the event loop object.
;; However, for consistency we deal with all operations on the event
;; pipe below via the mutex.
(define (_event-loop-reset! el)
  ;; the only foolproof way of vacating a unix pipe is to close it and
  ;; then create another one
  (with-mutex (_mutex-get el)
    ;; discard any EAGAIN exception when flushing the output buffer
    ;; of a fully filled pipe on closing
    (catch 'system-error
      (lambda ()
	(close-port (_event-in-get el))
	(close-port (_event-out-get el)))
      (lambda args
	(unless (= EAGAIN (system-error-errno args))
	  (apply throw args))))
      
    (let* ((event-pipe (pipe))
	   (in (car event-pipe))
	   (out (cdr event-pipe)))
      (fcntl out F_SETFL (logior O_NONBLOCK
				 (fcntl out F_GETFL)))
      (_event-in-set! el in)
      (_event-out-set! el out))
    (let ((q (_q-get el)))
      (let loop ()
	(when (not (q-empty? q))
	  (deq! q)
	  (loop))))
    (_done-set! el #f))
  (_read-files-set! el '())
  (_read-files-actions-set! el '())
  (_write-files-set! el '())
  (_write-files-actions-set! el '())
  (_timeouts-set! el '())
  (_current-timeout-set! el #f))

;; The 'proc' callback should take a single argument, and when called
;; this will be set to 'in or 'excpt.  The same port or file
;; descriptor can also be passed to event-loop-add-write-watch, and if
;; so and the descriptor is also available for writing, the write
;; callback will also be called with its argument set to 'out.  If
;; there is already a read watch for the file passed, the old one will
;; be replaced by the new one.  If proc returns #f, the read watch
;; (and any write watch for the same file) will be removed from the
;; event loop, otherwise the watch will continue.  This is thread safe
;; - any thread may add a watch, and the callback will execute in the
;; event loop thread.  The file argument can be either a port or a
;; file descriptor.  If 'file' is a file descriptor, any port for the
;; descriptor is not referenced for garbage collection purposes - it
;; must remain valid while operations are carried out on the
;; descriptor.  If 'file' is a buffered port, buffering will be taken
;; into account in indicating whether a read can be made without
;; blocking (but on a buffered port, for efficiency purposes each read
;; operation in response to this watch should usually exhaust the
;; buffer by looping on char-ready?).
(define (event-loop-add-read-watch! el file proc)
  (event-post! el (lambda ()
		    (_read-files-set!
		     el
		     (cons file
			   (delete! file (_read-files-get el) _file-equal?)))
		    (_read-files-actions-set!
		     el
		     (acons file proc
			    (alist-delete! file (_read-files-actions-get el) _file-equal?))))))

;; The 'proc' callback should take a single argument, and when called
;; this will be set to 'out or 'excpt.  The same port or file
;; descriptor can also be passed to event-loop-add-read-watch, and if
;; so and the descriptor is also available for reading or in error,
;; the read callback will also be called with its argument set to 'in
;; or 'excpt (if both a read and a write watch have been set for the
;; same file argument, and there is an exceptional condition, it is
;; the read watch procedure which will be called with 'excpt rather
;; than the write watch procedure).  If there is already a write watch
;; for the file passed, the old one will be replaced by the new one.
;; If proc returns #f, the write watch (and any read watch for the
;; same file) will be removed from the event loop, otherwise the watch
;; will continue.  This is thread safe - any thread may add a watch,
;; and the callback will execute in the event loop thread.  The file
;; argument can be either a port or a file descriptor.  If 'file' is a
;; file descriptor, any port for the descriptor is not referenced for
;; garbage collection purposes - it must remain valid while operations
;; are carried out on the descriptor.  If 'file' is a buffered port,
;; buffering will be taken into account in indicating whether a write
;; can be made without blocking.
(define (event-loop-add-write-watch! el file proc)
  (event-post! el (lambda ()
		    (_write-files-set!
		     el
		     (cons file
			   (delete! file (_write-files-get el) _file-equal?)))
		    (_write-files-actions-set!
		     el
		     (acons file proc
			    (alist-delete! file (_write-files-actions-get el) _file-equal?))))))

;; The file argument may be a port or a file descriptor, and this
;; removes any read and write watch previously entered for that port
;; or file descriptor.  This is thread safe - any thread may remove a
;; watch.  A file descriptor and a port with the same underlying file
;; descriptor compare equal for the purposes of removal.
(define (event-loop-remove-watch! el file)
  (event-post! el (lambda ()
		    (_remove-watch-impl! el file))))

;; The 'action' callback is a thunk.  This is thread safe - any thread
;; may post an event (that is its main purpose), and the action
;; callback will execute in the event loop thread.  Actions execute in
;; the order in which they were posted.  If an event is posted from a
;; worker thread, it will normally be necessary to call
;; event-loop-block! beforehand.
(define (event-post! el action)
  (with-mutex (_mutex-get el)
    (enq! (_q-get el) action)
    (let ((out (_event-out-get el)))
      ;; if the event pipe is full and an EAGAIN error arises, we
      ;; can just swallow it.  The only purpose of writing #\x is to
      ;; cause the select procedure to return and reloop to pick up
      ;; any new entries in the event queue.
      (catch 'system-error
	(lambda ()
	  (write-char #\x out)
	  (force-output out))
	(lambda args
	  (unless (= EAGAIN (system-error-errno args))
	    (apply throw args)))))))

;; This adds a timeout to the event loop.  The timeout will repeat
;; unless and until the passed-in callback returns #f or
;; timeout-remove! is called.  The passed-in callback must be a thunk.
;; This procedure returns a tag symbol to which timeout-remove! can be
;; applied.  It may be called by any thread.
(define (timeout-post! el msecs action)
  (let ((tag (gensym "timeout-"))
	(abstime (_get-abstime msecs)))
    (event-post! el
		 (lambda ()
		   (let ((new-timeouts (cons (vector abstime
						     tag
						     msecs
						     action)
					     (_timeouts-get el))))
		     (_timeouts-set! el new-timeouts)
		     (_current-timeout-set! el (_next-timeout new-timeouts)))))
    tag))

;; This stops the timeout with the given tag from executing in the
;; event loop concerned.  It may be called by any thread.
(define (timeout-remove! el tag)
  (event-post! el
	       (lambda ()
		 (_timeouts-set! el (_filter-timeout (_timeouts-get el) tag)))))
      
;; by default, upon there being no more watches, timeouts and posted
;; events for an event loop, event-loop-run! will return, which is
;; normally what you want with a single threaded program.  However,
;; this is undesirable where a worker thread is intended to post an
;; event to the main loop after it has reached a result, say via
;; await-task-in-thread, because the main loop may have ended before
;; it posts.  Passing #t to the val argument of this procedure will
;; prevent that from happening, so that the event loop can only be
;; ended by calling event-loop-quit!.  To switch it back to
;; non-blocking mode, pass #f.  This is thread safe - any thread may
;; call this procedure.
(define (event-loop-block! el val)
  (with-mutex (_mutex-get el)
    (let ((old-val (_block-get el)))
      (_block-set! el (not (not val)))
      (when (and old-val (not val))
	;; if the event pipe is full and an EAGAIN error arises, we
	;; can just swallow it.  The only purpose of writing #\x is to
	;; cause the select procedure to return and reloop and then
	;; exit the event loop if there are no further events.
	(let ((out (_event-out-get el)))
	  (catch 'system-error
	    (lambda ()
	      (write-char #\x out)
	      (force-output out))
	    (lambda args
	      (unless (= EAGAIN (system-error-errno args))
		(apply throw args)))))))))

;; Causes the event loop to unblock.  Any events remaining in the
;; event loop will be discarded.  New events may subsequently be added
;; after event-loop-run! has unblocked and event-loop-run! then called
;; for them.  This is thread safe - any thread may call this
;; procedure.
(define (event-loop-quit! el)
  (with-mutex (_mutex-get el)
    (_done-set! el #t)
    ;; if the event pipe is full and an EAGAIN error arises, we can
    ;; just swallow it.  The only purpose of writing #\x is to cause
    ;; the select procedure to return
    (let ((out (_event-out-get el)))
      (catch 'system-error
	(lambda ()
	  (write-char #\x out)
	  (force-output out))
	(lambda args
	  (unless (= EAGAIN (system-error-errno args))
	    (apply throw args)))))))

;; This is a convenience procedure which will run 'thunk' in its own
;; thread, and then post an event to the event loop specified by the
;; 'loop' argument when 'thunk' has finished.  This procedure calls
;; 'await' and will return the thunk's return value.  It is intended
;; to be called in a waitable procedure invoked by a-sync.  It will
;; normally be necessary to call event-loop-block! before invoking
;; this procedure.  If the optional 'handler' argument is provided,
;; then it will be run in the event loop thread if 'thunk' throws and
;; its return value will be the return value of this procedure;
;; otherwise the program will terminate if an unhandled exception
;; propagates out of 'thunk'.  'handler' should take the same
;; arguments as a guile catch handler (this is implemented using
;; catch).  If 'handler' throws, the exception will propagate out of
;; event-loop-run!.
(define* (await-task-in-thread! loop await resume thunk #:optional handler)
  (if handler
      (call-with-new-thread
       (lambda ()
	 (catch
	  #t
	  (lambda ()
	    (let ((res (thunk)))
	      (event-post! loop (lambda ()
				  (resume res)))))
	  (lambda args
	    (event-post! loop (lambda ()
				(resume (apply handler args))))))))
      (call-with-new-thread
       (lambda ()
	 (let ((res (thunk)))
	   (event-post! loop (lambda ()
			       (resume res)))))))
  (await))

;; This is a convenience procedure for use with an event loop, which
;; will run 'thunk' in the event loop specified by the 'loop'
;; argument.  This procedure calls 'await' and will return the thunk's
;; return value.  It is intended to be called in a waitable procedure
;; invoked by a-sync.  It is the single-threaded corollary of
;; await-task-in-thread!.  This means that (unlike with
;; await-task-in-thread!) while the task is running other events in
;; the event loop will not make progress.  This is not particularly
;; useful except when called by the event loop thread for the purpose
;; of bringing the event loop to an end at its own place in the event
;; queue, or when called by a worker thread to report a result
;; expected by a waitable procedure running in the event loop thread.
;; (For the latter case though, await-task-in-thread! is generally a
;; more convenient wrapper.)
(define (await-task! loop await resume thunk)
  (event-post! loop (lambda ()
		      (resume (thunk))))
  (await))

;; This is a convenience procedure for use with an event loop, which
;; will run 'thunk' in the event loop thread when the timeout expires.
;; This procedure calls 'await' and will return the thunk's return
;; value.  It is intended to be called in a waitable procedure invoked
;; by a-sync.  The timeout is single shot only - as soon as 'thunk'
;; has run once and completed, the timeout will be removed from the
;; event loop.
(define (await-timeout! loop msec await resume thunk)
  (timeout-post! loop msec
		 (lambda ()
		   (resume (thunk))
		   #f))
  (await))

;; This is a convenience procedure for use with an event loop, which
;; will run 'proc' in the event loop thread whenever 'file' is ready
;; for reading, and apply resume (obtained from a call to a-sync) to
;; the return value of 'proc'.  'file' can be a port or a file
;; descriptor (and if it is a file descriptor, the revealed count is
;; not incremented).  'proc' should take a single argument which will
;; be set by the event loop to 'in or 'excpt (see the documentation on
;; event-loop-add-read-watch! for further details).  It is intended to
;; be called in a waitable procedure invoked by a-sync.  The watch is
;; multi-shot - it is for the user to bring it to an end at the right
;; time by calling event-loop-remove-watch! in the waitable procedure.
;; This procedure is mainly intended as something from which
;; higher-level asynchronous file operations can be constructed, such
;; as the await-getline! procedure.
(define (a-sync-read-watch! loop file resume proc)
  (event-loop-add-read-watch! loop file
			      (lambda (status)
				(resume (proc status))
				#t)))

;; This is a convenience procedure for use with an event loop, which
;; will start a read watch on 'port' for a line of input.  It calls
;; 'await' while waiting for input and will return the line of text
;; received (without the terminating '\n' character).  The event loop
;; will not be blocked by this procedure even if only individual
;; characters are available at any one time.  It is intended to be
;; called in a waitable procedure invoked by a-sync.  This procedure
;; is implemented using a-sync-read-watch!.
(define (await-getline! loop port await resume)
  (define text '())
  (a-sync-read-watch! loop
		      port
		      resume
		      (lambda (status)
			(read-char port)))
  (let next ((ch (await)))
    (if (not (char=? ch #\newline))
	(begin
	  (set! text (cons ch text))
	  (next (await)))
	(begin
	  (event-loop-remove-watch! loop port)
	  (reverse-list->string text)))))

;; This is a convenience procedure for use with an event loop, which
;; will run 'proc' in the event loop thread whenever 'file' is ready
;; for writing, and apply resume (obtained from a call to a-sync) to
;; the return value of 'proc'.  'file' can be a port or a file
;; descriptor (and if it is a file descriptor, the revealed count is
;; not incremented).  'proc' should take a single argument which will
;; be set by the event loop to 'out or 'excpt (see the documentation
;; on event-loop-add-write-watch! for further details).  It is
;; intended to be called in a waitable procedure invoked by a-sync.
;; The watch is multi-shot - it is for the user to bring it to an end
;; at the right time by calling event-loop-remove-watch! in the
;; waitable procedure.  This procedure is mainly intended as something
;; from which higher-level asynchronous file operations can be
;; constructed.
(define (a-sync-write-watch! loop file resume proc)
  (event-loop-add-write-watch! loop file
			      (lambda (status)
				(resume (proc status))
				#t)))
