;;; rayfall-mode-test.el --- Tests for rayfall-mode -*- lexical-binding: t; -*-

(require 'ert)
(require 'rayfall-mode)

(ert-deftest rayfall-mode-parses-and-finds-expression ()
  (skip-unless (treesit-ready-p 'rayfall t))
  (with-temp-buffer
    (insert "(set square (fn [x]\n(* x x)))\n(square 5)\n")
    (rayfall-mode)
    (goto-char (point-min))
    (font-lock-ensure)
    (should (eq (get-text-property (1+ (point)) 'face)
                'font-lock-keyword-face))
    (search-forward "x x")
    (let ((bounds (rayfall--expression-bounds)))
      (should (equal (buffer-substring-no-properties (car bounds) (cdr bounds))
                     "(set square (fn [x]\n(* x x)))")))
    (should (equal (mapcar #'car (rayfall--imenu-index)) '("square")))))

(ert-deftest rayfall-mode-indents-nested-forms ()
  (skip-unless (treesit-ready-p 'rayfall t))
  (with-temp-buffer
    (insert "(select {from: trades\nwhere: (> price 100)})")
    (rayfall-mode)
    (indent-region (point-min) (point-max))
    (goto-char (point-min))
    (forward-line 1)
    (should (= (current-indentation) rayfall-indent-offset))))

(ert-deftest rayfall-mode-includes-adjacent-top-level-tokens ()
  (skip-unless (treesit-ready-p 'rayfall t))
  (with-temp-buffer
    (insert "0X\n(+ 1 2)\n")
    (rayfall-mode)
    (goto-char (point-min))
    (should (equal (rayfall--expression-bounds) '(1 . 3)))
    (forward-char 1)
    (should (equal (rayfall--expression-bounds) '(1 . 3)))
    (forward-line 1)
    (should (equal (buffer-substring-no-properties
                    (car (rayfall--expression-bounds))
                    (cdr (rayfall--expression-bounds)))
                   "(+ 1 2)"))))

(ert-deftest rayfall-repl-default-command-parts ()
  (let ((rayfall-program "/tmp/rayforce")
        (rayfall-program-arguments '("-c" "2")))
    (should
     (equal (mapconcat #'shell-quote-argument
                       (cons rayfall-program
                             (append rayfall-program-arguments '("--interactive")))
                       " ")
            "/tmp/rayforce -c 2 --interactive"))))

(ert-deftest rayfall-displays-and-clears-inline-result ()
  (with-temp-buffer
    (insert "(+ 1 2)")
    (let ((rayfall-display-eval-results t)
          (position (copy-marker (point-max))))
      (rayfall--display-eval-result (current-buffer) position "3")
      (should (overlayp rayfall--eval-result-overlay))
      (should (eq (overlay-buffer rayfall--eval-result-overlay)
                  (current-buffer)))
      (should (equal (overlay-get rayfall--eval-result-overlay 'after-string)
                     (propertize "  ⇒ 3" 'face 'rayfall-eval-result-face)))
      (insert " ")
      (should-not rayfall--eval-result-overlay))))

(ert-deftest rayfall-finishes-pending-evaluation-output ()
  (let ((source (generate-new-buffer " *rayfall-test-source*"))
        (repl (generate-new-buffer " *rayfall-test-repl*")))
    (unwind-protect
        (with-current-buffer source
          (insert "(+ 1 2)")
          (let ((source-position (copy-marker (point-max))))
            (with-current-buffer repl
              (insert "\33[32m3\33[0m\n")
              (let ((output-end (copy-marker (point-max))))
                (setq rayfall-repl--pending-eval
                      (list source source-position (copy-marker (point-min))
                            "delimiter"))
                (cl-letf (((symbol-function 'get-buffer-process)
                           (lambda (&optional _buffer) 'test-process))
                          ((symbol-function 'process-mark)
                           (lambda (_process) output-end)))
                  (rayfall--finish-pending-eval))))
            (should (equal (substring-no-properties
                            (overlay-get rayfall--eval-result-overlay
                                         'after-string))
                           "  ⇒ 3"))))
      (kill-buffer source)
      (kill-buffer repl))))

(ert-deftest rayfall-completes-output-only-at-delimiter ()
  (let ((source (generate-new-buffer " *rayfall-test-source*"))
        (repl (generate-new-buffer " *rayfall-test-repl*")))
    (unwind-protect
        (with-current-buffer source
          (insert ":env")
          (let ((source-position (copy-marker (point-max))))
            (with-current-buffer repl
              (insert "first chunk\n")
              (let ((process-mark (copy-marker (point-max))))
                (setq rayfall-repl--pending-eval
                      (list source source-position (copy-marker (point-min))
                            "__done__"))
                (cl-letf (((symbol-function 'get-buffer-process)
                           (lambda (&optional _buffer) 'test-process))
                          ((symbol-function 'process-mark)
                           (lambda (_process) process-mark)))
                  (should-not (rayfall--complete-pending-eval))
                  (should rayfall-repl--pending-eval)
                  (goto-char (point-max))
                  (insert "second chunk\n__done__\n")
                  (set-marker process-mark (point-max))
                  (should (rayfall--complete-pending-eval))
                  (should-not rayfall-repl--pending-eval)
                  (should-not (string-match-p "__done__" (buffer-string))))))
            (should (equal (substring-no-properties
                            (overlay-get rayfall--eval-result-overlay
                                         'after-string))
                           "  ⇒ first chunk\nsecond chunk"))))
      (kill-buffer source)
      (kill-buffer repl))))

(ert-deftest rayfall-send-string-keeps-result-marker-in-source-buffer ()
  (let ((source (generate-new-buffer " *rayfall-test-source*"))
        (repl (generate-new-buffer " *rayfall-test-repl*"))
        rayfall-repl-buffer)
    (unwind-protect
        (with-current-buffer source
          (insert "(+ 1 2)")
          (let ((rayfall-repl-buffer repl))
            (cl-letf (((symbol-function 'rayfall--ensure-repl)
                       (lambda () 'test-process))
                      ((symbol-function 'get-buffer-process)
                       (lambda (&optional _buffer) 'test-process))
                      ((symbol-function 'process-mark)
                       (lambda (_process) (with-current-buffer repl
                                            (point-max-marker))))
                      ((symbol-function 'comint-send-string)
                       (lambda (_process string)
                         (should (string-match-p
                                  "(println \"__rayfall_emacs_" string)))))
              (rayfall-send-string (buffer-string) (point-max))
              (should (eq (marker-buffer
                           (cadr (with-current-buffer repl
                                   rayfall-repl--pending-eval)))
                          source)))))
      (kill-buffer source)
      (kill-buffer repl))))

;;; rayfall-mode-test.el ends here
