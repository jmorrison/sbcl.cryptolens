(defstruct foo)

(with-test (:name :xset-hash-equal)
  (let ((list `(sym ,(make-foo) 1 -12d0 4/3 #\z ,(ash 1 70)))
        (a (sb-int:alloc-xset)))
    (dolist (elt list)
      (sb-int:add-to-xset elt a))
    (dotimes (i 10)
      (let ((b (sb-int:alloc-xset)))
        (dolist (elt (shuffle list))
          (sb-int:add-to-xset elt b))
        (assert (sb-int:xset= a b))
        (assert (= (sb-int:xset-elts-hash a)
                   (sb-int:xset-elts-hash b)))))))