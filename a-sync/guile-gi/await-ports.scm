;; Copyright (C) 2016 to 2020 Chris Vine

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

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; When using the guile-gi bindings for gtk+, in order to provide
;; await semantics on gtk+ callbacks it will normally be necessary to
;; use the 'await' and 'resume' procedures provided by the a-sync
;; procedure in the (a-sync coroutines) module directly (calling
;; 'resume' in the gtk+ callback when ready, and waiting on that
;; callback using 'await').  However when launching timeouts, file
;; watches or other events on the glib main loop using guile-gi,
;; convenience procedures are possible similar to those provided for
;; the event loop in the (a-sync event-loop) module.  These are set
;; out in the files in this directory.
;;
;; Most of the scheme files provided by this library are by default
;; compiled by this library to bytecode.  That is not the case with
;; this file, so as not to create a hard dependency on guile-gi.

(define-module (a-sync guile-gi await-ports)
  #:use-module (ice-9 rdelim)                ;; for read-line
  #:use-module (ice-9 textual-ports)         ;; for put-string
  #:use-module (ice-9 binary-ports)          ;; for get-u8
  #:use-module (ice-9 control)               ;; for call/ec
  #:use-module (ice-9 suspendable-ports)
  #:use-module (gi)
  #:use-module (gi repository)
  #:use-module (gi types)
  #:use-module (rnrs bytevectors)            ;; for bytevectors
  #:export (await-glib-read-suspendable
	    await-glib-getline
	    await-glib-geteveryline
	    await-glib-getsomelines
	    await-glib-getblock
	    await-glib-geteveryblock
	    await-glib-getsomeblocks
	    await-glib-write-suspendable
	    await-glib-put-bytevector
	    await-glib-put-string
	    await-glib-accept
	    await-glib-connect))

;; NOTE: The procedures which may be used with
;; await-glib-read-suspendable and await-glib-write-suspendable cover
;; most but not all i/o procedures.  Thus, the following are safe to
;; use with non-blocking suspendable ports: read-char, get-char,
;; peek-char, lookahead-char, read-line, get-line, get-u8,
;; lookahead-u8, get-bytevector-n, get-string-all, write-char,
;; put-char, put-u8, put-string, put-bytevector, newline, force-output
;; and flush-output-port.  For sockets, the accept and connect
;; procedures are also safe.
;;
;; Some others are not at present safe to use with suspendable ports,
;; including get-bytevector-n!, get-bytevector-some,
;; get-bytevector-all, get-string-n, read, write and display.
;; Unfortunately this means that some of the procedures in guile's web
;; module cannot be used with suspendable ports.  build-uri,
;; build-request and cognates are fine, as is write-request if no
;; custom header writers are imported, but the read-response-body
;; procedure is not.  This means that http-get, http-put and so on
;; cannot normally be used: an example of a safe procedure for reading
;; http responses is in the example-client.scm file in the docs
;; directory.  In addition, guile-gnutls ports are not suspendable.
;; (One answer where only a few gnutls sessions are to be run
;; concurrently is to run each such session in a separate thread using
;; await-glib-task-in-thread or await-glib-task-in-thread-pool, and to
;; use synchronous guile-gnutls i/o in the session.)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(install-suspendable-ports!)

(eval-when (load compile eval)
  (require "GLib" "2.0")
  (load-by-name "GLib" "unix_fd_add_full")
  (load-by-name "GLib" "source_remove")
  (load-by-name "GLib" "PRIORITY_DEFAULT")
  (load-by-name "GLib" "IOCondition"))

(define (glib-add-watch fd condition proc)
  (unix-fd-add-full PRIORITY_DEFAULT
		    fd
		    (list->flags <GIOCondition> condition)
		    (lambda args ;; (fd cond data)
		      (proc (flags->list <GIOCondition> (cadr args))))
		    #f
		    (lambda ignore #f)))


;; 'proc' is a procedure taking a single argument, to which the port
;; will be passed when it is invoked.  The purpose of 'proc' is to
;; carry out i/o operations on 'port' using the port's normal read
;; procedures.  'port' must be a suspendable non-blocking port.  This
;; procedure will return when 'proc' returns, as if by blocking read
;; operations, with the value returned by 'proc'.  However, the glib
;; main loop will not be blocked by this procedure even if only
;; individual characters or bytes comprising part characters are
;; available at any one time.  It is intended to be called in a
;; waitable procedure invoked by a-sync (which supplies the 'await'
;; and 'resume' arguments).  'proc' must not itself explicitly apply
;; 'await' and 'resume' as those are potentially in use by the
;; suspendable port while 'proc' is executing.
;;
;; If an exceptional condition ('pri) is encountered by the
;; implementation, #f will be returned by this procedure and the read
;; operations to be performed by 'proc' will be abandonned; there is
;; however no guarantee that any exceptional condition that does arise
;; will be encountered by the implementation - the user procedure
;; 'proc' may get there first and deal with it, or it may not.
;; However exceptional conditions are very rare, usually comprising
;; only out-of-band data on a TCP socket, or a pseudoterminal master
;; in packet mode seeing state change in a slave.  In the absence of
;; an exceptional condition, the value(s) returned by 'proc' will be
;; returned.
;;
;; This procedure must (like the a-sync procedure) be called in the
;; same thread as that in which the default glib main loop runs.
;;
;; Exceptions (say, from 'proc' because of port or conversion errors)
;; will propagate out of this procedure in the first instance, and if
;; not caught locally will then propagate out of main-loop:run.
;;
;; Unlike the await-* procedures in the (a-sync g-golf base) module,
;; this procedure will not call 'await' if the read operation(s) in
;; 'proc' can be effected immediately without waiting: instead, after
;; reading this procedure would return straight away without invoking
;; the glib main loop.
;;
;; This procedure is first available in version 0.19 of this library.
(define (await-glib-read-suspendable await resume port proc)
  (define id #f)
  (define (read-waiter p)
    (when (not id)
      (set! id (glib-add-watch (port->fdes port)
			       '(in hup err pri)
			       (lambda (condition)
				 (if (memq 'pri condition)
				     (resume 'excpt)
				     (resume))
				 #t))))
    (when (eq? (await) 'except)
      (throw 'except)))
  (call-with-values
    (lambda ()
      (parameterize ((current-read-waiter read-waiter))
	(catch #t
	  (lambda ()
	    (proc port))
	  (lambda args
	    (if (eq? (car args) 'except)
		#f
		(begin
		  (when id
		    (source-remove? id)
		    (release-port-handle port))
		  (apply throw args)))))))
    (lambda args
      (when id
	(source-remove? id)
	(release-port-handle port))
      (apply values args))))

;; This procedure is provided mainly to retain compatibility with the
;; guile-a-sync library for guile-2.0, because it is trivial to
;; implement with await-glib-read-suspendable (and is implemented by
;; await-glib-read-suspendable).
;;
;; It is intended to be called in a waitable procedure invoked by
;; a-sync, and reads a line of text from a non-blocking suspendable
;; port and returns it (without the terminating '\n' character).  See
;; the documentation on the await-glib-read-suspendable procedure for
;; further particulars about this procedure.
;;
;; This procedure is first available in version 0.19 of this library.
(define (await-glib-getline await resume port)
  (await-glib-read-suspendable await resume port
			       (lambda (p)
				 (read-line p))))

;; This procedure is provided mainly to retain compatibility with the
;; guile-a-sync library for guile-2.0, because it is trivial to
;; implement with await-glib-read-suspendable (and is implemented by
;; await-glib-read-suspendable).
;;
;; It is intended to be called within a waitable procedure invoked by
;; a-sync (which supplies the 'await' and 'resume' arguments), and
;; will apply 'proc' to every complete line of text received (without
;; the terminating '\n' character).  The watch will not end until
;; end-of-file or an exceptional condition ('pri) is reached.  In the
;; event of that happening, this procedure will end and return an
;; end-of-file object or #f respectively.
;;
;; When 'proc' executes, 'await' and 'resume' will still be in use by
;; this procedure, so they may not be reused by 'proc' (even though
;; 'proc' runs in the event loop thread).
;;
;; See the documentation on the await-glib-read-suspendable procedure
;; for further particulars about this procedure.
;;
;; This procedure is first available in version 0.19 of this library.
(define (await-glib-geteveryline await resume port proc)
  (await-glib-read-suspendable await resume port
			       (lambda (p)
				 (let next ((line (read-line p)))
				   (if (or (eof-object? line)
					   (not line))
				       line
				       (begin
					 (proc line)
					 (next (read-line p))))))))

;; This procedure is intended to be called within a waitable procedure
;; invoked by a-sync (which supplies the 'await' and 'resume'
;; arguments), and does the same as await-glib-geteveryline, except
;; that it provides a second argument to 'proc', namely an escape
;; continuation which can be invoked by 'proc' to cause the procedure
;; to return before end-of-file is reached.  Behavior is identical to
;; await-glib-geteveryline if the continuation is not invoked.
;;
;; This procedure will apply 'proc' to every complete line of text
;; received (without the terminating '\n' character).  The watch will
;; not end until end-of-file or an exceptional condition ('pri) is
;; reached, which would cause this procedure to end and return an
;; end-of-file object or #f respectively, or until the escape
;; continuation is invoked, in which case the value passed to the
;; escape continuation will be returned.
;;
;; When 'proc' executes, 'await' and 'resume' will still be in use by
;; this procedure, so they may not be reused by 'proc' (even though
;; 'proc' runs in the event loop thread).
;;
;; See the documentation on the await-glib-read-suspendable procedure
;; for further particulars about this procedure.
;;
;; This procedure is first available in version 0.19 of this library.
(define (await-glib-getsomelines await resume port proc)
  (await-glib-read-suspendable await resume port
			       (lambda (p)
				 (call/ec
				  (lambda (k)
				    (let next ((line (read-line p)))
				      (if (or (eof-object? line)
					      (not line))
					  line
					  (begin
					    (proc line k)
					    (next (read-line p))))))))))

;; This procedure is provided mainly to retain compatibility with the
;; guile-a-sync library for guile-2.0, because an implementation is
;; trivial to implement with await-glib-read-suspendable (and is
;; implemented by await-glib-read-suspendable).
;;
;; It is intended to be called in a waitable procedure invoked by
;; a-sync, and reads a block of data, such as a binary record, of size
;; 'size' from a non-blocking suspendable port 'port'.  This procedure
;; will return a pair, normally comprising as its car a bytevector of
;; length 'size' containing the data, and as its cdr the number of
;; bytes received and placed in the bytevector (which will be the same
;; as 'size' unless an end-of-file object was encountered part way
;; through receiving the data).  If an end-of-file object is
;; encountered without any bytes of data, a pair with eof-object as
;; car and #f as cdr will be returned.
;;
;; See the documentation on the await-glib-read-suspendable procedure
;; for further particulars about this procedure.
;;
;; This procedure is first available in version 0.19 of this library.
(define (await-glib-getblock await resume port size)
  (define bv (make-bytevector size))
  (define index 0)
  (await-glib-read-suspendable await resume port
			       (lambda (p)
				 (let next ((u8 (get-u8 p)))
				   (if (eof-object? u8)
				       (if (= index 0)
					   (cons u8 #f)
					   (cons bv index))
				       (begin
					 (bytevector-u8-set! bv index u8)
					 (set! index (1+ index))
					 (if (= index size)
					     (cons bv size)
					     (next (get-u8 p)))))))))

;; This procedure is provided mainly to retain compatibility with the
;; guile-a-sync library for guile-2.0, because it is trivial to
;; implement this kind of functionality with
;; await-glib-read-suspendable (and is implemented by
;; await-glib-read-suspendable).
;;
;; It is intended to be called within a waitable procedure invoked by
;; a-sync (which supplies the 'await' and 'resume' arguments), and
;; will apply 'proc' to any block of data received, such as a binary
;; record.  'proc' should be a procedure taking two arguments, first a
;; bytevector of length 'size' containing the block of data read and
;; second the size of the block of data placed in the bytevector.  The
;; value passed as the size of the block of data placed in the
;; bytevector will always be the same as 'size' unless end-of-file has
;; been encountered after receiving only a partial block of data.  The
;; watch will not end until end-of-file or an exceptional condition
;; ('pri) is reached.  In the event of that happening, this procedure
;; will end and return an end-of-file object or #f respectively.
;;
;; For efficiency reasons, this procedure passes its internal
;; bytevector buffer to 'proc' as proc's first argument and, when
;; 'proc' returns, re-uses it.  Therefore, if 'proc' stores its first
;; argument for use after 'proc' has returned, it should store it by
;; copying it.
;;
;; When 'proc' executes, 'await' and 'resume' will still be in use by
;; this procedure, so they may not be reused by 'proc' (even though
;; 'proc' runs in the event loop thread).
;;
;; See the documentation on the await-glib-read-suspendable procedure
;; for further particulars about this procedure.
;;
;; This procedure is first available in version 0.19 of this library.
(define (await-glib-geteveryblock await resume port size proc)
  ;; we cannot use get-bytevector-n! because it is not async-safe in
  ;; suspendable ports, so build the bytevector by hand
  (define bv (make-bytevector size))
  (define index 0)
  (await-glib-read-suspendable await resume port
			       (lambda (p)
				 (let next ((u8 (get-u8 p)))
				   (if (eof-object? u8)
				       (begin
					 (when (> index 0)
					   (proc bv index))
					 u8)
				       (begin
					 (bytevector-u8-set! bv index u8)
					 (set! index (1+ index))
					 (when (= index size)
					   (set! index 0)
					   (proc bv size))
					 (next (get-u8 p))))))))

;; This procedure is intended to be called within a waitable procedure
;; invoked by a-sync (which supplies the 'await' and 'resume'
;; arguments), and does the same as await-glib-geteveryblock, except
;; that it provides a third argument to 'proc', namely an escape
;; continuation which can be invoked by 'proc' to cause the procedure
;; to return before end-of-file is reached.  Behavior is identical to
;; await-glib-geteveryblock if the continuation is not invoked.
;;
;; This procedure will apply 'proc' to any block of data received,
;; such as a binary record.  'proc' should be a procedure taking three
;; arguments, first a bytevector of length 'size' containing the block
;; of data read, second the size of the block of data placed in the
;; bytevector and third an escape continuation.  The value passed as
;; the size of the block of data placed in the bytevector will always
;; be the same as 'size' unless end-of-file has been encountered after
;; receiving only a partial block of data.  The watch will not end
;; until end-of-file or an exceptional condition ('pri) is reached,
;; which would cause this procedure to end and return an end-of-file
;; object or #f respectively, or until the escape continuation is
;; invoked, in which case the value passed to the escape continuation
;; will be returned.
;;
;; For efficiency reasons, this procedure passes its internal
;; bytevector buffer to 'proc' as proc's first argument and, when
;; 'proc' returns, re-uses it.  Therefore, if 'proc' stores its first
;; argument for use after 'proc' has returned, it should store it by
;; copying it.
;;
;; When 'proc' executes, 'await' and 'resume' will still be in use by
;; this procedure, so they may not be reused by 'proc' (even though
;; 'proc' runs in the event loop thread).
;;
;; See the documentation on the await-glib-read-suspendable procedure
;; for further particulars about this procedure.
;;
;; This procedure is first available in version 0.19 of this library.
(define (await-glib-getsomeblocks await resume port size proc)
  ;; we cannot use get-bytevector-n! because it is not async-safe in
  ;; suspendable ports, so build the bytevector by hand
  (define bv (make-bytevector size))
  (define index 0)
  (await-glib-read-suspendable await resume port
			       (lambda (p)
				 (call/ec
				  (lambda (k)
				    (let next ((u8 (get-u8 p)))
				      (if (eof-object? u8)
					  (begin
					    (when (> index 0)
					      (proc bv index k))
					    u8)
					  (begin
					    (bytevector-u8-set! bv index u8)
					    (set! index (1+ index))
					    (when (= index size)
					      (set! index 0)
					      (proc bv size k))
					    (next (get-u8 p))))))))))

;; 'proc' is a procedure taking a single argument, to which the port
;; will be passed when it is invoked.  The purpose of 'proc' is to
;; carry out i/o operations on 'port' using the port's normal write
;; procedures.  'port' must be a suspendable non-blocking port.  This
;; procedure will return when 'proc' returns, as if by blocking write
;; operations, with the value(s) returned by 'proc'.  However, the
;; glib main loop will not be blocked by this procedure even if only
;; individual characters or bytes comprising part characters can be
;; written at any one time.  It is intended to be called in a waitable
;; procedure invoked by a-sync (which supplies the 'await' and
;; 'resume' arguments).  'proc' must not itself explicitly apply
;; 'await' and 'resume' as those are potentially in use by the
;; suspendable port while 'proc' is executing.
;;
;; This procedure must (like the a-sync procedure) be called in the
;; same thread as that in which the default glib main loop runs.
;;
;; Exceptions (say, from 'proc' because of port or conversion errors)
;; will propagate out of this procedure in the first instance, and if
;; not caught locally will then propagate out of main-loop:run.
;;
;; Unlike the await-* procedures in the (a-sync g-golf base) module,
;; this procedure will not call 'await' if the write operation(s) in
;; 'proc' can be effected immediately without waiting: instead, after
;; writing this procedure would return straight away without invoking
;; the glib main loop.
;;
;; This procedure is first available in version 0.19 of this library.
(define (await-glib-write-suspendable await resume port proc)
  (define id #f)
  (define (write-waiter p)
    (when (not id)
      (set! id (glib-add-watch (port->fdes port)
			       '(out err)
			       (lambda (condition)
				 (resume)
				 #t))))
    (await))
  (call-with-values
    (lambda ()
      (parameterize ((current-write-waiter write-waiter))
	(catch #t
	  (lambda ()
	    (proc port))
	  (lambda args
	    (when id
	      (source-remove? id)
	      (release-port-handle port))
	    (apply throw args)))))
    (lambda args
      (when id
	(source-remove? id)
	(release-port-handle port))
      (apply values args))))

;; This procedure is provided mainly to retain compatibility with the
;; guile-a-sync library for guile-2.0, because it is trivial to
;; implement with await-glib-write-suspendable (and is implemented by
;; await-glib-write-suspendable).
;;
;; It is intended to be called in a waitable procedure invoked by
;; a-sync, and will write a bytevector to the port.
;;
;; See the documentation on the await-glib-write-suspendable procedure
;; for further particulars about this procedure.
;;
;; This procedure is first available in version 0.19 of this library.
(define (await-glib-put-bytevector await resume port bv)
  (await-glib-write-suspendable await resume port
				(lambda (p)
				  (put-bytevector p bv)
				  ;; enforce a flush when the current
				  ;; write-waiter is still in
				  ;; operation
				  (force-output p))))

;; This procedure is provided mainly to retain compatibility with the
;; guile-a-sync library for guile-2.0, because it is trivial to
;; implement with await-glib-write-suspendable (and is implemented by
;; await-glib-write-suspendable).
;;
;; It is intended to be called in a waitable procedure invoked by
;; a-sync, and will write a string to the port.
;;
;; If CR-LF line endings are to be written when outputting the string,
;; the '\r' character (as well as the '\n' character) must be embedded
;; in the string.
;;
;; See the documentation on the await-glib-write-suspendable procedure
;; for further particulars about this procedure.
;;
;; This procedure is first available in version 0.19 of this library.
(define (await-glib-put-string await resume port text)
  (await-glib-write-suspendable await resume port
				(lambda (p)
				  (put-string p text)
				  ;; enforce a flush when the current
				  ;; write-waiter is still in
				  ;; operation
				  (force-output p))))

;; This procedure is provided mainly to retain compatibility with the
;; guile-a-sync library for guile-2.0, because it is trivial to
;; implement with await-glib-read-suspendable (and is implemented by
;; await-glib-read-suspendable).
;;
;; This procedure will start a watch on listening socket 'sock' for a
;; connection.  'sock' must be a non-blocking socket port.  This
;; procedure wraps the guile 'accept' procedure and therefore returns
;; a pair, comprising as car a connection socket, and as cdr a socket
;; address object containing particulars of the address of the remote
;; connection.  This procedure is intended to be called within a
;; waitable procedure invoked by a-sync (which supplies the 'await'
;; and 'resume' arguments).
;;
;; See the documentation on the await-glib-read-suspendable procedure for
;; further particulars about this procedure.
;;
;; This procedure is first available in version 0.19 of this library.
(define (await-glib-accept await resume sock)
  (await-glib-read-suspendable await resume sock
			       (lambda (s)
				 (accept s))))

;; This procedure is provided mainly to retain compatibility with the
;; guile-a-sync library for guile-2.0, because it is trivial to
;; implement with await-glib-write-suspendable (and is implemented by
;; await-glib-write-suspendable).
;;
;; This procedure will connect socket 'sock' to a remote host.
;; Particulars of the remote host are given by 'args' which are the
;; arguments (other than 'sock') taken by guile's 'connect' procedure,
;; which this procedure wraps.  'sock' must be a non-blocking socket
;; port.  This procedure is intended to be called in a waitable
;; procedure invoked by a-sync (which supplies the 'await' and
;; 'resume' arguments).
;;
;; There are cases where it will not be helpful to use this procedure.
;; Where a connection request is immediately followed by a write to
;; the remote server (say, a get request), the call to 'connect' and
;; to 'put-string' can be combined in a single procedure passed to
;; await-glib-write-suspendable.
;;
;; See the documentation on the await-glib-write-suspendable procedure
;; for further particulars about this procedure.
;;
;; This procedure is first available in version 0.19 of this library.
(define (await-glib-connect await resume sock . args)
  (await-glib-write-suspendable await resume sock
				(lambda (s)
				  (apply connect s args)
				  #t)))
