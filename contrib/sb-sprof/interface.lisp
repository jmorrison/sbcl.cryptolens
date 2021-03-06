;;;; User interface of the statistical profiler
;;;;
;;;; Copyright (C) 2003 Gerd Moellmann <gerd.moellmann@t-online.de>
;;;; All rights reserved.

(in-package #:sb-sprof)

(defvar *sample-interval* 0.01
  "Default number of seconds between samples.")
(declaim (type (real (0)) *sample-interval*))

(defvar *alloc-interval* 4
  "Default number of allocation region openings between samples.")
(declaim (type (integer (0)) *alloc-interval*))

(defvar *max-samples* 50000
  "Default maximum number of stack traces collected.")
(declaim (type sb-int:index *max-samples*))

(defvar *sampling-mode* :cpu
  "Default sampling mode. :CPU for cpu profiling, :ALLOC for allocation
profiling, and :TIME for wallclock profiling.")
(declaim (type sampling-mode *sampling-mode*))

(defmacro with-profiling ((&key (sample-interval '*sample-interval*)
                                (alloc-interval '*alloc-interval*)
                                (max-samples '*max-samples*)
                                (reset nil)
                                (mode '*sampling-mode*)
                                (loop nil)
                                (max-depth most-positive-fixnum)
                                show-progress
                                (threads :all)
                                (report nil report-p))
                          &body body)
  "Evaluate BODY with statistical profiling turned on. If LOOP is true,
loop around the BODY until a sufficient number of samples has been collected.
Returns the values from the last evaluation of BODY.

The following keyword args are recognized:

 :SAMPLE-INTERVAL <n>
   Take a sample every <n> seconds. Default is *SAMPLE-INTERVAL*.

 :ALLOC-INTERVAL <n>
   Take a sample every time <n> allocation regions (approximately
   8kB) have been allocated since the last sample. Default is
   *ALLOC-INTERVAL*.

 :MODE <mode>
   If :CPU, run the profiler in CPU profiling mode. If :ALLOC, run the
   profiler in allocation profiling mode. If :TIME, run the profiler
   in wallclock profiling mode.

 :MAX-SAMPLES <max>
   If :LOOP is NIL (the default), collect no more than <max> samples.
   If :LOOP is T, repeat evaluating body until <max> samples are taken.
   Default is *MAX-SAMPLES*.

 :MAX-DEPTH <max>
   Maximum call stack depth that the profiler should consider. Only
   has an effect on x86 and x86-64.

 :REPORT <type>
   If specified, call REPORT with :TYPE <type> at the end.

 :RESET <bool>
   If true, call RESET at the beginning.

 :THREADS <list-form>
   Form that evaluates to the list threads to profile, or :ALL to indicate
   that all threads should be profiled. Defaults to all threads.

   :THREADS has no effect on call-counting at the moment.

   On some platforms (eg. Darwin) the signals used by the profiler are
   not properly delivered to threads in proportion to their CPU usage
   when doing :CPU profiling. If you see empty call graphs, or are obviously
   missing several samples from certain threads, you may be falling afoul
   of this. In this case using :MODE :TIME is likely to work better.

 :LOOP <bool>
   If false (the default), evaluate BODY only once. If true repeatedly
   evaluate BODY."
  (declare (type report-type report))
  (check-type loop boolean)
  #-sb-thread (unless (eq threads :all) (warn ":THREADS is ignored"))
  (let ((message "~@<No sampling progress; run too short, sampling frequency too low, ~
inappropriate set of sampled threads, or possibly a profiler bug.~:@>"))
    (with-unique-names (values last-index)
      `(let ((*show-progress* ,show-progress))
         ,@(when reset '((reset)))
         (unwind-protect
              (progn
                (start-profiling :mode ,mode :max-depth ,max-depth :max-samples ,max-samples
                                 :sample-interval ,sample-interval :alloc-interval ,alloc-interval
                                 :threads ,threads)
                ,(if loop
                     `(let (,values)
                        (loop ; Uh, shouldn't this be a trailing test, not a leading test?
                          (when (>= (samples-trace-count *samples*)
                                    (samples-max-samples *samples*))
                            (return))
                          (show-progress "~&===> ~d of ~d samples taken.~%"
                                         (samples-trace-count *samples*)
                                         (samples-max-samples *samples*))
                          (let ((,last-index (samples-index *samples*)))
                            (setf ,values (multiple-value-list (progn ,@body)))
                            (when (= ,last-index (samples-index *samples*))
                              (warn ,message)
                              (return))))
                        (values-list ,values))
                     `(let ((,last-index (samples-index *samples*)))
                        (multiple-value-prog1 (progn ,@body)
                          (when (= ,last-index (samples-index *samples*))
                            (warn ,message))))))
           (stop-profiling))
         ,@(when report-p `((report :type ,report)))))))

#-win32
(defun start-profiling (&key (max-samples *max-samples*)
                        (mode *sampling-mode*)
                        (sample-interval *sample-interval*)
                        (alloc-interval *alloc-interval*)
                        (max-depth most-positive-fixnum)
                        (threads :all))
  "Start profiling statistically in the current thread if not already profiling.
The following keyword args are recognized:

   :SAMPLE-INTERVAL <n>
     Take a sample every <n> seconds.  Default is *SAMPLE-INTERVAL*.

   :ALLOC-INTERVAL <n>
     Take a sample every time <n> allocation regions (approximately
     8kB) have been allocated since the last sample. Default is
     *ALLOC-INTERVAL*.

   :MODE <mode>
     If :CPU, run the profiler in CPU profiling mode. If :ALLOC, run
     the profiler in allocation profiling mode. If :TIME, run the profiler
     in wallclock profiling mode.

   :MAX-SAMPLES <max>
     Maximum number of stack traces to collect.  Default is *MAX-SAMPLES*.

   :MAX-DEPTH <max>
     Maximum call stack depth that the profiler should consider. Only
     has an effect on x86 and x86-64.

   :THREADS <list>
     List threads to profile, or :ALL to indicate that all threads should be
     profiled. Defaults to :ALL.

     :THREADS has no effect on call-counting at the moment.

     On some platforms (eg. Darwin) the signals used by the profiler are
     not properly delivered to threads in proportion to their CPU usage
     when doing :CPU profiling. If you see empty call graphs, or are obviously
     missing several samples from certain threads, you may be falling afoul
     of this."
  #-gencgc
  (when (eq mode :alloc)
    (error "Allocation profiling is only supported for builds using the generational garbage collector."))
  #-sb-thread (unless (eq threads :all) (warn ":THREADS is ignored"))
  (unless *profiling*
    (multiple-value-bind (secs usecs)
        (multiple-value-bind (secs rest)
            (truncate sample-interval)
          (values secs (truncate (* rest 1000000))))
      ;; I'm 99% sure that unconditionally assigning *SAMPLES* is a bug,
      ;; because doing it makes the RESET function (and the :RESET keyword
      ;; to WITH-PROFILING) meaningless - what's the difference between
      ;; resetting and not resetting if either way causes all previously
      ;; acquired traces to disappear? My intuition would have been that
      ;; start/stop/start/stop should leave *SAMPLES* holding a union of all
      ;; traces captured by both "on" periods, whereas with a RESET in between
      ;; it would not. But they behave identically, because this is a reset.
      (setf *samples* (make-samples :max-depth max-depth
                                    :max-samples max-samples
                                    :sample-interval sample-interval
                                    :alloc-interval alloc-interval
                                    :mode mode))
      (enable-call-counting)
      #+sb-thread (setf sb-thread::*profiled-threads* threads)
      ;; Each existing threads' sprof-enable slot needs to reflect the desired set.
      (sb-thread::avltree-filter
       (lambda (node &aux (thread (sb-thread::avlnode-data node)))
         (if (or (eq threads :all) (memq thread threads))
             (start-sampling thread)
             (stop-sampling thread)))
       sb-thread::*all-threads*)
      ;;
      (sb-sys:enable-interrupt sb-unix:sigprof
                               #'sigprof-handler)
      (flet (#+sb-thread
             (map-threads (function &aux (threads sb-thread::*profiled-threads*))
               (if (listp threads)
                   (mapc function threads)
                   (named-let visit ((node sb-thread::*all-threads*))
                     (awhen (sb-thread::avlnode-left node) (visit it))
                     (awhen (sb-thread::avlnode-right node) (visit it))
                     (let ((thread (sb-thread::avlnode-data node)))
                       (when (and (= (sb-thread::thread-%visible thread) 1)
                                  (neq thread *timer*))
                         (funcall function thread)))))))
       (ecase mode
        (:alloc
         (let ((alloc-signal (1- alloc-interval)))
           #+sb-thread
           (progn
             (when (eq :all threads)
               ;; Set the value new threads inherit.
               ;; This used to acquire the all-threads lock, but I fail to see how
               ;; doing so ensured anything at all. Maybe because our locks tend
               ;; to act as memory barriers? Anyway, what's the point?
               (progn
                 (setf sb-thread::*default-alloc-signal* alloc-signal)))
             ;; Turn on allocation profiling in existing threads.
             (map-threads
              (lambda (thread)
                (sb-thread::%set-symbol-value-in-thread 'sb-vm::*alloc-signal* thread alloc-signal))))
           #-sb-thread
           (setf sb-vm:*alloc-signal* alloc-signal)))
        (:cpu
         (unix-setitimer :profile secs usecs secs usecs))
        (:time
         #+sb-thread
         (sb-thread::start-thread
          (setf *timer* (sb-thread::%make-thread "SPROF timer" nil (sb-thread:make-semaphore)))
          (lambda ()
            (loop (unless *timer* (return))
                  (sleep sample-interval)
                  (map-threads
                   (lambda (thread)
                     (sb-thread:with-deathlok (thread c-thread)
                       (unless (= c-thread 0)
                         (sb-thread:pthread-kill (sb-thread::thread-os-thread thread)
                                                 sb-unix:sigprof)))))))
          nil)
         #-sb-thread
         (schedule-timer
          (setf *timer* (make-timer (lambda () (unix-kill 0 sb-unix:sigprof))
                                    :name "SPROF timer"))
          sample-interval :repeat-interval sample-interval))))
      (setq *profiling* mode)))
  (values))

(defun stop-profiling ()
  "Stop profiling if profiling."
  (let ((profiling *profiling*))
    (when profiling
      ;; Even with the timers shut down we cannot be sure that there is no
      ;; undelivered sigprof. The handler is also responsible for turning the
      ;; *ALLOC-SIGNAL* off in individual threads.
      (ecase profiling
        (:alloc
         #+sb-thread
         (setf sb-thread::*default-alloc-signal* nil)
         #-sb-thread
         (setf sb-vm:*alloc-signal* nil))
        (:cpu
         (unix-setitimer :profile 0 0 0 0))
        (:time
         (let ((timer *timer*))
           ;; after this assignment, the timer thread will raise the
           ;; profiling signal at most once more, and then stop.
           (setf *timer* nil)
           #-sb-thread (unschedule-timer timer)
           #+sb-thread (sb-thread:join-thread timer))))
     (disable-call-counting)
     ;; New threads should not mask SIGPROF by default
     #+sb-thread (setf sb-thread::*profiled-threads* :all)
     (setf *profiling* nil)))
  (values))

(defun reset ()
  "Reset the profiler."
  (stop-profiling)
  (setq *samples* nil)
  (values))
