;;;; Sample recording and storage functions of the statistical profiler
;;;;
;;;; Copyright (C) 2003 Gerd Moellmann <gerd.moellmann@t-online.de>
;;;; All rights reserved.

(in-package #:sb-sprof)


;;; Append-only sample vector

(deftype sampling-mode ()
  '(member :cpu :alloc :time))

;;; 0 code-component-ish
;;; 1 an offset relative to the start of the code-component or an
;;;   absolute address
(defconstant +elements-per-pc-loc+ 2)

;;; 0 the trace start marker (trace-start . END-INDEX)
;;; 1 the current thread, an SB-THREAD:THREAD instance
(defconstant +elements-per-trace-start+ 2)

(declaim (inline make-sample-vector))
(defun make-sample-vector (max-samples)
  (make-array (* max-samples
                 ;; Arbitrary guess at how many pc-locs we'll be
                 ;; taking for each trace. The exact amount doesn't
                 ;; matter, this is just to decrease the amount of
                 ;; re-allocation that will need to be done.
                 10
                 ;; Each pc-loc takes two cells in the vector
                 +elements-per-pc-loc+)))

;;; Encapsulate all the information about a sampling run
(defstruct (samples
             (:constructor
              make-samples (&key mode sample-interval alloc-interval
                                 max-depth max-samples
                            &aux (vector (make-sample-vector max-samples)))))
  ;; When this vector fills up, we allocate a new one and copy over
  ;; the old contents.
  (vector          nil                  :type simple-vector)
  (index           0                    :type sb-int:index)
  ;; Only used while recording a trace. Stores a cell that is
  ;;
  ;;   (start-trace . nil)   (start-trace is the marker symbol
  ;;                          SB-SPROF:START-TRACE)
  ;;
  ;; when starting to record a trace and
  ;;
  ;;   (start-trace . END-INDEX-OF-THE-TRACE)
  ;;
  ;; after finishing recording the trace. This allows MAP-TRACES to
  ;; jump from one trace to the next in O(1) instead of O(N) time.
  (trace-start     '(nil . nil)         :type cons)
  (trace-count     0                    :type sb-int:index)

  (sampled-threads nil                  :type list)

  ;; Metadata
  (mode            nil                  :type sampling-mode              :read-only t)
  (sample-interval (sb-int:missing-arg) :type (real (0))                 :read-only t)
  (alloc-interval  (sb-int:missing-arg) :type (integer (0))              :read-only t)
  (max-depth       most-positive-fixnum :type (and fixnum (integer (0))) :read-only t)
  (max-samples     (sb-int:missing-arg) :type sb-int:index               :read-only t))

(defmethod print-object ((samples samples) stream)
  (let ((*print-array* nil))
    (call-next-method)))

(defun note-sample-vector-full (samples)
  (format *trace-output* "Profiler sample vector full (~:D trace~:P / ~
                          approximately ~:D sample~:P), doubling the ~
                          size~%"
          (samples-trace-count samples)
          (truncate (samples-index samples) +elements-per-pc-loc+)))

(declaim (inline ensure-samples-vector))
(defun ensure-samples-vector (samples)
  (declare (optimize (speed 3)))
  (let ((vector (samples-vector samples))
        (index (samples-index samples)))
    ;; Allocate a new sample vector if the current one is too small to
    ;; accommodate the largest chunk of elements that we could
    ;; potentially store in one go (currently 3 elements, stored by
    ;; RECORD-TRACE-START).
    (values (if (< (length vector) (+ index (max +elements-per-pc-loc+
                                                 +elements-per-trace-start+)))
                (let ((new-vector (make-array (* 2 index))))
                  (note-sample-vector-full samples)
                  (replace new-vector vector)
                  (setf (samples-vector samples) new-vector))
                vector)
            index)))

(defun record-trace-start (samples)
  ;; Mark the start of the trace.
  (multiple-value-bind (vector index) (ensure-samples-vector samples)
    (let ((trace-start (cons 'trace-start nil)))
      (setf (aref vector index)       trace-start
            (aref vector (+ index 1)) sb-thread:*current-thread*)
      (setf (samples-index samples)       (+ index +elements-per-trace-start+)
            (samples-trace-start samples) trace-start))))

(defun record-trace-end (samples)
  (setf (cdr (samples-trace-start samples)) (samples-index samples)))

(declaim (inline record-sample))
(defun record-sample (samples info pc-or-offset)
  (multiple-value-bind (vector index) (ensure-samples-vector samples)
    ;; For each sample, store the debug-info and the PC/offset into
    ;; adjacent cells.
    (setf (aref vector index) info
          (aref vector (1+ index)) pc-or-offset)
    (setf (samples-index samples) (+ index +elements-per-pc-loc+))))

;;; Trace and sample and access functions

(defun map-traces (function samples)
  "Call FUNCTION on each trace in SAMPLES

The signature of FUNCTION must be compatible with (thread trace).

FUNCTION is called once for each trace where THREAD is the SB-THREAD:TREAD
instance which was sampled to produce TRACE, and TRACE is an opaque object
to be passed to MAP-TRACE-PC-LOCS.

EXPERIMENTAL: Interface subject to change."
  (let ((function (sb-kernel:%coerce-callable-to-fun function))
        (vector (samples-vector samples))
        (index (samples-index samples)))
    (when (plusp index)
      (sb-int:aver (typep (aref vector 0) '(cons (eql trace-start) index)))
      (loop for start = 0 then end
            while (< start index)
            for end = (cdr (aref vector start))
            for thread = (aref vector (+ start 1))
            do (let ((trace (list vector start end)))
                 (funcall function thread trace))))))

;;; Call FUNCTION on each PC location in TRACE.
;;; The signature of FUNCTION must be compatible with (info pc-or-offset).
;;; TRACE is an object as received by the function passed to MAP-TRACES.
(defun map-trace-pc-locs (function trace)
  (let ((function (sb-kernel:%coerce-callable-to-fun function)))
    (destructuring-bind (samples start end) trace
      (loop for i from (- end +elements-per-pc-loc+)
            downto (+ start +elements-per-trace-start+ -1)
            by +elements-per-pc-loc+
            for info = (aref samples i)
            for pc-or-offset = (aref samples (1+ i))
            do (funcall function info pc-or-offset)))))

;;; One "sample" is a trace, usually. But also it means an instance of SAMPLES,
;;; but also it means a PC location expressed as code + offset.
;;; So when is a sample not a sample? When it's a PC location.
(declaim (type (or null samples) *samples*))
(defglobal *samples* nil)

;;; Call FUNCTION on each PC location in SAMPLES which is usually
;;; the value of *SAMPLES* after a profiling run.
;;; The signature of FUNCTION must be compatible with (info pc-or-offset).
(defun map-all-pc-locs (function &optional (samples *samples*))
  (sb-int:dx-flet ((do-trace (thread trace)
                     (declare (ignore thread))
                     (map-trace-pc-locs function trace)))
    (map-traces #'do-trace samples)))

(defun sample-pc (info pc-or-offset)
  "Extract and return program counter from INFO and PC-OR-OFFSET.

Can be applied to the arguments passed by MAP-TRACE-PC-LOCS and
MAP-ALL-PC-LOCS.

EXPERIMENTAL: Interface subject to change."
  (etypecase info
    ;; Assembly routines or foreign functions don't move around, so
    ;; we've stored a raw PC
    ((or null sb-kernel:code-component string symbol)
     pc-or-offset)
    ;; Lisp functions might move, so we've stored a offset from the
    ;; start of the code component.
    (sb-di::compiled-debug-fun
     (let ((component (sb-di::compiled-debug-fun-component info)))
       (sap-int (sap+ (sb-kernel:code-instructions component) pc-or-offset))))))

;;; Sampling

;;; *PROFILING* is both the global enabling flag, and the operational mode.
(defvar *profiling* nil)
(declaim (type (or (eql nil) sampling-mode) *profiling*))

(defvar *show-progress* nil)

;; Call count encapsulation information
(defvar *encapsulations* (make-hash-table :test 'equal))

(defun show-progress (format-string &rest args)
  (when *show-progress*
    (apply #'format t format-string args)
    (finish-output)))

(define-alien-routine "sb_toggle_sigprof" int (context system-area-pointer) (state int))
(eval-when (:compile-toplevel)
  ;; current-thread-offset-sap has no slot setter, let alone for other threads,
  ;; nor for sub-fields of a word, so ...
  (defmacro sprof-enable-byte () ; see 'thread.h'
    (+ (ash sb-vm:thread-state-word-slot sb-vm:word-shift) 1)))

;;; If a thread wants sampling but had previously blocked SIGPROF,
;;; it will have to unblock the signal. We can use %INTERRUPT-THREAD
;;; to tell it to do that.
(defun start-sampling (&optional (thread sb-thread:*current-thread*))
  "Unblock SIGPROF in the specified thread"
  (if (eq thread sb-thread:*current-thread*)
      (when (zerop (sap-ref-8 (sb-thread:current-thread-sap) (sprof-enable-byte)))
        (setf (sap-ref-8 (sb-thread:current-thread-sap) (sprof-enable-byte)) 1)
        (sb-toggle-sigprof (if (boundp 'sb-kernel:*current-internal-error-context*)
                               sb-kernel:*current-internal-error-context*
                               (sb-sys:int-sap 0))
                           0))
      ;; %INTERRUPT-THREAD requires that the interruptions lock be held by the caller.
      (sb-thread:with-deathlok (thread c-thread)
        (when (and (/= c-thread 0)
                   (zerop (sap-ref-8 (int-sap c-thread) (sprof-enable-byte))))
          (sb-thread::%interrupt-thread thread #'start-sampling))))
  nil)

(defun stop-sampling (&optional (thread sb-thread:*current-thread*))
  "Block SIGPROF in the specified thread"
  (sb-thread:with-deathlok (thread c-thread)
    (when (and (/= c-thread 0)
               (not (zerop (sap-ref-8 (int-sap c-thread) (sprof-enable-byte)))))
      (setf (sap-ref-8 (int-sap c-thread) (sprof-enable-byte)) 0)
      ;; Blocking the signal is done lazily in threads other than the current one.
      (when (eq thread sb-thread:*current-thread*)
        (sb-toggle-sigprof (sb-sys:int-sap 0) 1)))) ; 1 = mask it
  nil)

(defun call-with-sampling (enable thunk)
  (declare (dynamic-extent thunk))
  (if (= (sap-ref-8 (sb-thread:current-thread-sap) (sprof-enable-byte))
         (if enable 1 0))
      ;; Already in the correct state
      (funcall thunk)
      ;; Invert state, call thunk, invert again
      (progn (if enable (start-sampling) (stop-sampling))
             (unwind-protect (funcall thunk)
               (if enable (stop-sampling) (start-sampling))))))

(defmacro with-sampling ((&optional (on t)) &body body)
  "Evaluate body with statistical sampling turned on or off in the current thread."
  `(call-with-sampling (if ,on t nil) (lambda () ,@body)))

;;; Return something serving as debug info for address PC.
(declaim (inline debug-info))
(defun debug-info (pc)
  (declare (type system-area-pointer pc)
           (muffle-conditions compiler-note))
  (let ((code (sb-di::code-header-from-pc pc))
        (pc-int (sap-int pc)))
    (cond ((not code)
           (let ((name (sap-foreign-symbol pc)))
             (if name
                 (values (format nil "foreign function ~a" name)
                         pc-int :foreign)
                 (values nil pc-int :foreign))))
          ((eq code sb-fasl:*assembler-routines*)
           (values (sb-disassem::find-assembler-routine pc-int)
                   pc-int :asm-routine))
          (t
           (let* (;; Give up if we land in the 2 or 3 instructions of a
                  ;; code component sans simple-fun that is not an asm routine.
                  ;; While it's conceivable that this could be improved,
                  ;; the problem will be different or nonexistent after
                  ;; funcallable-instances each contain their own trampoline.
                  #+immobile-code
                  (di (unless (typep (sb-kernel:%code-debug-info code)
                                     'sb-c::compiled-debug-info)
                        (return-from debug-info
                          (values code pc-int nil))))
                  (pc-offset (sap- (int-sap pc-int) (sb-kernel:code-instructions code)))
                  (df (sb-di::debug-fun-from-pc code pc-offset)))
             #+immobile-code (declare (ignorable di))
             (cond ((typep df 'sb-di::bogus-debug-fun)
                    (values code pc-int nil))
                   (df
                    ;; The code component might be moved by the GC. Store
                    ;; a PC offset, and reconstruct the data in SAMPLE-PC
                    (values df pc-offset nil))
                   (t
                    (values nil 0 nil))))))))

(declaim (inline record))
(defun record (samples pc)
  (declare (type system-area-pointer pc))
  (multiple-value-bind (info pc-or-offset foreign) (debug-info pc)
    (record-sample samples info pc-or-offset)
    foreign))

;;; In wallclock mode, *TIMER* is an instance of either SB-THREAD:THREAD
;;; or SB-EXT:TIMER depending on whether thread support exists.
(defglobal *timer* nil)

#+(and (or x86 x86-64) (not win32))
(progn
  ;; Ensure that only one thread at a time will be doing profiling stuff.
  (defglobal *profiler-lock* (sb-thread:make-mutex :name "Statistical Profiler"))

  (defun sigprof-handler (signal code scp)
    (declare (ignore signal code) (optimize speed)
             (disable-package-locks sb-di::x86-call-context)
             (muffle-conditions compiler-note)
             (type system-area-pointer scp))
    (when (zerop (sap-ref-8 (sb-thread:current-thread-sap) (sprof-enable-byte)))
      ;; This thread does not want sampling, but received a profiling signal.
      (sb-toggle-sigprof scp 1) ; block further signals
      (return-from sigprof-handler))
    (let ((self sb-thread:*current-thread*)
          (profiling *profiling*))
      ;; Turn off allocation counter when it is not needed. Doing this in the
      ;; signal handler means we don't have to worry about racing with the runtime
      (unless (eq :alloc profiling)
        (setf sb-vm::*alloc-signal* nil))
      (with-code-pages-pinned (:dynamic)
         (with-system-mutex (*profiler-lock*)
          (let ((samples *samples*)
                ;; Don't touch the circularity hash-table
                *print-circle*)
            (when (and samples
                       (< (samples-trace-count samples)
                          (samples-max-samples samples)))
              (with-alien ((scp (* os-context-t) :local scp))
                (let* ((pc-ptr (sb-vm:context-pc scp))
                       (fp (sb-vm::context-register scp
                                                    #+x86-64 #.sb-vm::rbp-offset
                                                    #+x86 #.sb-vm::ebp-offset)))
                  ;; foreign code might not have a useful frame
                  ;; pointer in ebp/rbp, so make sure it looks
                  ;; reasonable before walking the stack
                  (unless (sb-di::control-stack-pointer-valid-p (sb-sys:int-sap fp))
                    (return-from sigprof-handler nil))
                  (incf (samples-trace-count samples))
                  (pushnew self (samples-sampled-threads samples))
                  (let ((fp (int-sap fp))
                        (ok t))
                    (declare (type system-area-pointer fp pc-ptr))
                    ;; FIXME: How annoying. The XC doesn't store enough
                    ;; type information about SB-DI::X86-CALL-CONTEXT,
                    ;; even if we declaim the ftype explicitly in
                    ;; src/code/debug-int. And for some reason that type
                    ;; information is needed for the inlined version to
                    ;; be compiled without boxing the returned saps. So
                    ;; we declare the correct ftype here manually, even
                    ;; if the compiler should be able to deduce this
                    ;; exact same information.
                    (declare (ftype (function (system-area-pointer)
                                              (values (member nil t)
                                                      system-area-pointer
                                                      system-area-pointer))
                                    sb-di::x86-call-context))
                    (record-trace-start samples)
                    (dotimes (i (samples-max-depth samples))
                      (record samples pc-ptr)
                      (setf (values ok pc-ptr fp)
                            (sb-di::x86-call-context fp))
                      (unless ok
                        ;; If we fail to walk the stack beyond the
                        ;; initial frame, there is likely something
                        ;; wrong. Undo the trace start marker and the
                        ;; one sample we already recorded.
                        (when (zerop i)
                          (decf (samples-index samples)
                                (+ +elements-per-trace-start+
                                   (* +elements-per-pc-loc+ (1+ i)))))
                        (return)))
                    (record-trace-end samples))))
              ;; Reset thread-local allocation counter before interrupts
              ;; are enabled.
              (when (eq t sb-vm::*alloc-signal*)
                (setf sb-vm:*alloc-signal* (1- (samples-alloc-interval samples)))))))))
    nil))

;; FIXME: On non-x86 platforms we don't yet walk the call stack deeper
;; than one level.
#-(or x86 x86-64)
(defun sigprof-handler (signal code scp)
  (declare (ignore signal code))
  (when (zerop (sap-ref-8 (sb-thread:current-thread-sap) (sprof-enable-byte)))
    ;; This thread does not want sampling, but received a profiling signal.
    (sb-toggle-sigprof scp 1) ; block further signals
    (return-from sigprof-handler))
  (sb-sys:without-interrupts
    (let ((samples *samples*))
      (when (and samples
                 (< (samples-trace-count samples)
                    (samples-max-samples samples)))
        (sb-sys:without-gcing
          (with-alien ((scp (* os-context-t) :local scp))
            (locally (declare (optimize (inhibit-warnings 2)))
              (incf (samples-trace-count samples))
              (record-trace-start samples)
              (let ((pc-ptr (sb-vm:context-pc scp))
                    (fp (sb-vm::context-register scp #.sb-vm::cfp-offset)))
                (unless (eq (record samples pc-ptr) :foreign)
                  (record samples (sap-ref-sap
                                   (int-sap fp)
                                   (* sb-vm::lra-save-offset sb-vm::n-word-bytes)))))
              (record-trace-end samples))))))))
