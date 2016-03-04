;; Copyright Chris Vine 2016

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


;; When using the scheme (gnome gtk) bindings of guile-gnome with
;; guile, in order to provide await semantics on gtk+ callbacks it
;; will normally be necessary to use the 'await' and 'resume'
;; procedures provided by the a-sync procedure in the (a-sync
;; coroutines) module directly (calling 'resume' in the gtk+ callback
;; when ready, and waiting on that callback using 'await').  However
;; when launching timeouts, file watches or idle events on the glib
;; main loop, convenience procedures are possible similar to those
;; provided for the event loop in the (a-sync event-loop) module.
;; These are set out below.
;;
;; Note that the g-idle-add procedure in guile-gnome is suspect -
;; there appears to be a garbage collection issue, and if you call the
;; procedure often enough in a single or multi-threaded program it
;; will eventually segfault.  g-io-add-watch is also broken in
;; guile-gnome, so this file uses its own glib-add-watch procedure
;; which is exported publicly in case it is useful to users.
;;
;; All the other scheme files provided by this library are by default
;; compiled by this library to bytecode.  That is not the case with
;; this file, so as not to create a hard dependency on guile-gnome.

(define-module (a-sync gnome-glib)
  #:use-module (gnome glib)            ;; for g-io-channel-* and g-source-*
  #:use-module (gnome gobject)         ;; for gclosure
  #:use-module (oop goops)             ;; for make
  #:export (await-glib-task-in-thread
	    await-glib-task
	    await-glib-timeout
	    glib-add-watch
	    a-sync-glib-read-watch
	    a-sync-glib-write-watch
	    await-glib-getline))


;; This is a convenience procedure which will run 'thunk' in its own
;; thread, and then post an event to the default glib main loop when
;; 'thunk' has finished.  This procedure calls 'await' and will return
;; the thunk's return value.  It is intended to be called in a
;; waitable procedure invoked by a-sync.  If the optional 'handler'
;; argument is provided, then it will be run in the event loop thread
;; if 'thunk' throws and its return value will be the return value of
;; this procedure; otherwise the program will terminate if an
;; unhandled exception propagates out of 'thunk'.  'handler' should
;; take the same arguments as a guile catch handler (this is
;; implemented using catch).  If 'handler' throws, the exception will
;; propagate out of g-mail-loop-run.
(define* (await-glib-task-in-thread await resume thunk #:optional handler)
  (if handler
      (call-with-new-thread
       (lambda ()
	 (catch
	  #t
	  (lambda ()
	    (let ((res (thunk)))
	      (g-idle-add (lambda ()
			    (resume res)
			    #f))))
	  (lambda args
	    (g-idle-add (lambda ()
			  (resume (apply handler args))
			  #f))))))
      (call-with-new-thread
       (lambda ()
	 (let ((res (thunk)))
	   (g-idle-add (lambda ()
			 (resume res)
			 #f))))))
  (await))

;; This is a convenience procedure for use with glib, which will run
;; 'thunk' in the default glib main loop.  This procedure calls
;; 'await' and will return the thunk's return value.  It is intended
;; to be called in a waitable procedure invoked by a-sync.  It is the
;; single-threaded corollary of await-glib-task-in-thread.  This means
;; that (unlike with await-glib-task-in-thread) while 'thunk' is
;; running other events in the main loop will not make progress.  This
;; is not particularly useful except when called by the main loop
;; thread for the purpose of bringing the loop to an end at its own
;; place in the event queue, or when called by a worker thread to
;; report a result expected by a waitable procedure running in the
;; main loop thread.  (For the latter case though,
;; await-glib-task-in-thread is generally a more convenient wrapper.)
(define (await-glib-task await resume thunk)
  (g-idle-add (lambda ()
		(resume (thunk))
		#f))
  (await))

;; This is a convenience procedure for use with a glib main loop,
;; which will run 'thunk' in the default glib main loop when the
;; timeout expires.  This procedure calls 'await' and will return the
;; thunk's return value.  It is intended to be called in a waitable
;; procedure invoked by a-sync.  The timeout is single shot only - as
;; soon as 'thunk' has run once and completed, the timeout will be
;; removed from the event loop.
(define (await-glib-timeout msec await resume thunk)
  (g-timeout-add msec
		 (lambda ()
		   (resume (thunk))
		   #f))
  (await))

;; This procedure replaces guile-gnome's g-io-add-watch procedure,
;; which won't compile.  It attaches a watch on a g-io-channel object
;; to the main context provided, or if none is provided, to the
;; default glib main context (the main program loop).  It returns a
;; glib ID which can be passed subsequently to the g-source-remove
;; procedure.
(define* (glib-add-watch ioc cond func #:optional context)
  (let ((s (g-io-create-watch ioc cond))
        (closure (make <gclosure>
                   #:return-type <gboolean>
                   #:func func)))
    (g-source-set-closure s closure)
    (g-source-attach s context)))

;; This is a convenience procedure for use with a glib main loop,
;; which will run 'proc' in the default glib main loop whenever 'port'
;; is ready for reading, and apply resume (obtained from a call to
;; a-sync) to the return value of 'proc'.  'proc' should take two
;; arguments, the first of which will be set by glib to the
;; g-io-channel object constructed for the watch and the second of
;; which will be set to the GIOCondition ('in, 'pri, 'hup or 'err)
;; provided by glib which caused the watch to activate.  It is
;; intended to be called in a waitable procedure invoked by a-sync.
;; The watch is multi-shot - it is for the user to bring it to an end
;; at the right time by calling g-source-remove in the waitable
;; procedure on the id tag returned by this procedure.  The revealed
;; count of the file descriptor underlying the port is incremented,
;; and it is also for the programmer, when removing the watch, to call
;; release-port-handle on the port.  This procedure is mainly intended
;; as something from which higher-level asynchronous file operations
;; can be constructed, such as the await-glib-getline procedure.
(define (a-sync-glib-read-watch port resume proc)
  (glib-add-watch (g-io-channel-unix-new (port->fdes port))
		  '(in pri hup err)
		  (lambda (a b)
		    (resume (proc a b))
		    #t)))
			   
;; This is a convenience procedure for use with a glib main loop,
;; which will start a file watch and run 'thunk' in the default glib
;; main loop whenver an entire line of text has been received.  This
;; procedure calls 'await' while waiting for input and will return the
;; line of text received (without the terminating '\n' character).
;; The event loop will not be blocked by this procedure even if only
;; individual characters are available at any one time.  It is
;; intended to be called in a waitable procedure invoked by a-sync.
;; This procedure is implemented using a-sync-glib-read-watch.
(define (await-glib-getline port await resume)
  (define text '())
  (define id (a-sync-glib-read-watch port
				     resume
				     (lambda (ioc status)
				       (read-char port))))
  (let next ((ch (await)))
    (if (not (char=? ch #\newline))
	(begin
	  (set! text (cons ch text))
	  (next (await)))
	(begin
	  (g-source-remove id)
	  (release-port-handle port)
	  (reverse-list->string text)))))
	
;; This is a convenience procedure for use with a glib main loop,
;; which will run 'proc' in the default glib main loop whenever 'port'
;; is ready for writing, and apply resume (obtained from a call to
;; a-sync) to the return value of 'proc'.  'proc' should take two
;; arguments, the first of which will be set by glib to the
;; g-io-channel object constructed for the watch and the second of
;; which will be set to the GIOCondition ('out or 'err) provided by
;; glib which caused the watch to activate.  It is intended to be
;; called in a waitable procedure invoked by a-sync.  The watch is
;; multi-shot - it is for the user to bring it to an end at the right
;; time by calling g-source-remove in the waitable procedure on the id
;; tag returned by this procedure.  The revealed count of the file
;; descriptor underlying the port is incremented, and it is also for
;; the programmer, when removing the watch, to call
;; release-port-handle on the port.  This procedure is mainly intended
;; as something from which higher-level asynchronous file operations
;; can be constructed.
(define (a-sync-glib-write-watch port resume proc)
  (glib-add-watch (g-io-channel-unix-new (port->fdes port))
		  '(out err)
		  (lambda (a b)
		    (resume (proc a b))
		    #t)))
			   
