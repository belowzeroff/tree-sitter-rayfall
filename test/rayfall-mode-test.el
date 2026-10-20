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

(defun rayfall-test--indent (text)
  "Return TEXT, stripped of indentation, as `rayfall-mode' indents it."
  (with-temp-buffer
    (insert (replace-regexp-in-string "^[ \t]+" "" text))
    (rayfall-mode)
    (indent-region (point-min) (point-max))
    (buffer-string)))

(defmacro rayfall-test--indents (name doc &rest cases)
  "Define test NAME (DOC): each case is a string already indented right."
  `(ert-deftest ,name ()
     ,doc
     (skip-unless (treesit-ready-p 'rayfall t))
     (dolist (want (list ,@cases))
       (should (equal (rayfall-test--indent want) want)))))

(rayfall-test--indents rayfall-mode-indents-call-arguments
  "Arguments line up under the first argument, or under the function."
  "(list (select a)\n      (select b))"
  "(concat\n \"a\"\n \"b\")"
  "(if (> x 0) 1\n    (< x 0) -1\n    0)"
  "(map (fn [i] (* i i))\n     (til n))")

(rayfall-test--indents rayfall-mode-indents-bodies
  "Body forms indent their body from their parenthesis, or from an
enclosing body form that opens on the same line."
  "(set f (fn [x]\n  (let y (* x x))\n  (+ y 1)))"
  "(let lots\n  (map (fn [i]\n         (* i i))\n       (til n)))"
  "(while (< j n)\n  (set j (+ j 1)))"
  "(do\n  (println 1)\n  2)"
  "(fn\n    [x]\n  x)")

(rayfall-test--indents rayfall-mode-indents-data
  "Vector elements and dictionary pairs line up with the first one."
  "(select {from: trades\n         where: (> price 100)})"
  "[1 2\n 3]"
  "{\n a: 1\n b: 2}"
  "{a:\n   (+ 1 2)}")

(rayfall-test--indents rayfall-mode-indents-comments-and-closers
  "Comments indent like code; a lone closer goes under its opener."
  "(set f (fn [x]\n  ;; square it\n  (* x x)))"
  "(list 1\n      2\n)")

(rayfall-test--indents rayfall-mode-indents-timespan-dictionaries
  "Timespan literals do not disturb dictionary or call indentation."
  "(set cfg {start: 2026.01.01D00:00:00.000
          period: 1D
          steps: 3})"
  "(set cfg {period: 0D01:00:00 steps: 3
          buy_policy: 'REJECT})"
  "(list [1D 0Nn
       -0D00:00:00.000000001]
      1.5e)")

(ert-deftest rayfall-mode-highlights-new-literals ()
  "New literals are single nodes with numeric or constant highlighting."
  (skip-unless (treesit-ready-p 'rayfall t))
  (dolist (literal '(("1D" "timespan" font-lock-number-face)
                     ("-0D00:00:00.000000001" "timespan" font-lock-number-face)
                     ("0Wn" "timespan" font-lock-number-face)
                     ("-0Wn" "timespan" font-lock-number-face)
                     ("1.5e" "float" font-lock-number-face)
                     ("1e-3e" "float" font-lock-number-face)
                     ("1e-3" "float" font-lock-number-face)
                     ("0Nn" "null" font-lock-constant-face)
                     ("0Ne" "null" font-lock-constant-face)
                     ("0Ng" "null" font-lock-constant-face)))
    (with-temp-buffer
      (insert (car literal))
      (rayfall-mode)
      (font-lock-ensure)
      (let* ((root (treesit-buffer-root-node 'rayfall))
             (node (treesit-node-child root 0 t)))
        (should (= (treesit-node-child-count root t) 1))
        (should (equal (treesit-node-type node) (nth 1 literal)))
        (should (equal (treesit-node-text node) (car literal))))
      (dotimes (offset (length (car literal)))
        (should (eq (get-text-property (1+ offset) 'face)
                    (nth 2 literal)))))))

(ert-deftest rayfall-mode-keeps-string-continuation-lines ()
  "Lines inside a multi-line string are text, not code."
  (skip-unless (treesit-ready-p 'rayfall t))
  (let ((src "(format\n\"a\n  b\n\" x)"))
    (with-temp-buffer
      (insert src)
      (rayfall-mode)
      (indent-region (point-min) (point-max))
      (should (equal (buffer-string) "(format\n \"a\n  b\n\" x)")))))

(ert-deftest rayfall-mode-distinguishes-hyphenated-functions-from-operators ()
  (skip-unless (treesit-ready-p 'rayfall t))
  (with-temp-buffer
    (insert "(sym-name x)\n(- 2 1)\n")
    (rayfall-mode)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "sym-name")
    (should (eq (get-text-property (match-beginning 0) 'face)
                'font-lock-function-call-face))
    (search-forward "-")
    (should (eq (get-text-property (match-beginning 0) 'face)
                'font-lock-operator-face))))

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

(ert-deftest rayfall-xref-finds-bindings-and-parameters ()
  (skip-unless (treesit-ready-p 'rayfall t))
  (with-temp-buffer
    (insert "(set square (fn [x] (* x x)))\n(square 5)\n")
    (rayfall-mode)
    (goto-char (point-min))
    (search-forward "square" nil nil 2)
    (backward-char)
    (should (equal (rayfall--identifier-at-point) "square"))
    (let ((definitions (rayfall--xref-definitions "square")))
      (should (= (length definitions) 1))
      (should (= (xref-buffer-location-position
                  (xref-item-location (car definitions)))
                 6)))
    (should (= (length (rayfall--xref-definitions "x")) 1))))

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
          (position (copy-marker (point-max)))
          popup-text popup-point deleted)
      (cl-letf (((symbol-function 'popup-tip)
                 (lambda (text &rest args)
                   (setq popup-text text)
                   (setq popup-point (plist-get args :point))
                   'test-popup))
                ((symbol-function 'popup-delete)
                 (lambda (popup)
                   (should (eq popup 'test-popup))
                   (setq deleted t))))
        (rayfall--display-eval-result (current-buffer) position "3")
        (should (eq rayfall--eval-result-overlay 'test-popup))
        (should (integerp popup-point))
        (should (= popup-point (point-max)))
        (should (equal (substring-no-properties popup-text) " 3"))
        (should (equal (get-text-property 0 'face popup-text)
                       '(:background inherit)))
        (should-not (get-text-property 1 'face popup-text))
        (insert " ")
        (should deleted)
        (should-not rayfall--eval-result-overlay)))))

(ert-deftest rayfall-clears-inline-result-after-point-moves ()
  (with-temp-buffer
    (insert "(+ 1 2)")
    (goto-char (point-min))
    (let ((rayfall-display-eval-results t)
          (position (copy-marker (point-max)))
          deleted)
      (cl-letf (((symbol-function 'popup-tip)
                 (lambda (&rest _args) 'test-popup))
                ((symbol-function 'popup-delete)
                 (lambda (popup)
                   (should (eq popup 'test-popup))
                   (setq deleted t))))
        (rayfall--display-eval-result (current-buffer) position "3")
        (should (memq #'rayfall--clear-eval-result-after-point-move
                      post-command-hook))
        (run-hooks 'post-command-hook)
        (should-not deleted)
        (forward-char)
        (run-hooks 'post-command-hook)
        (should deleted)
        (should-not rayfall--eval-result-overlay)
        (should-not (memq #'rayfall--clear-eval-result-after-point-move
                          post-command-hook))))))

(ert-deftest rayfall-finishes-pending-evaluation-output ()
  (let ((source (generate-new-buffer " *rayfall-test-source*"))
        (repl (generate-new-buffer " *rayfall-test-repl*")))
    (unwind-protect
        (with-current-buffer source
          (insert "(+ 1 2)")
          (let ((source-position (copy-marker (point-max))) displayed)
            (with-current-buffer repl
              (insert "\33[32m3\33[0m\n")
              (let ((output-end (copy-marker (point-max))))
                (setq rayfall-repl--pending-eval
                      (list source source-position (copy-marker (point-min))
                            "delimiter" (copy-marker (point-min))))
                (cl-letf (((symbol-function 'get-buffer-process)
                           (lambda (&optional _buffer) 'test-process))
                          ((symbol-function 'process-mark)
                           (lambda (_process) output-end))
                          ((symbol-function 'rayfall--display-eval-result)
                           (lambda (_buffer _position result)
                             (setq displayed result))))
                  (rayfall--finish-pending-eval))))
            (should (equal displayed "3"))))
      (kill-buffer source)
      (kill-buffer repl))))

(ert-deftest rayfall-completes-output-only-at-delimiter ()
  (let ((source (generate-new-buffer " *rayfall-test-source*"))
        (repl (generate-new-buffer " *rayfall-test-repl*")))
    (unwind-protect
        (with-current-buffer source
          (insert ":env")
          (let ((source-position (copy-marker (point-max))) displayed)
            (with-current-buffer repl
              (insert "first chunk\n")
              (let ((process-mark (copy-marker (point-max))))
                (setq rayfall-repl--pending-eval
                      (list source source-position (copy-marker (point-min))
                            "__done__" (copy-marker (point-min))))
                (cl-letf (((symbol-function 'get-buffer-process)
                           (lambda (&optional _buffer) 'test-process))
                          ((symbol-function 'process-mark)
                           (lambda (_process) process-mark))
                          ((symbol-function 'rayfall--display-eval-result)
                           (lambda (_buffer _position result)
                             (setq displayed result))))
                  (should-not (rayfall--complete-pending-eval))
                  (should rayfall-repl--pending-eval)
                  (goto-char (point-max))
                  (insert "second chunk\n__done__\n")
                  (set-marker process-mark (point-max))
                  (should (rayfall--complete-pending-eval))
                  (should-not rayfall-repl--pending-eval)
                  (should (string-empty-p (buffer-string))))))
            (should (equal displayed "first chunk\nsecond chunk"))))
      (kill-buffer source)
      (kill-buffer repl))))

(ert-deftest rayfall-consumes-completion-response ()
  (with-temp-buffer
    (insert "['sym-name 'symbol]\n__done__\n")
    (let ((process-mark (copy-marker (point-max))))
      (setq rayfall-repl--completion-request
            (list (copy-marker (point-min)) "__done__"))
      (cl-letf (((symbol-function 'get-buffer-process)
                 (lambda (&optional _buffer) 'test-process))
                ((symbol-function 'process-mark)
                 (lambda (_process) process-mark)))
        (should (rayfall--complete-completion-request))
        (should (equal rayfall-repl--completion-result
                       '("sym-name" "symbol")))
        (should-not rayfall-repl--completion-request)
        (should (string-empty-p (buffer-string)))))))

(ert-deftest rayfall-completion-at-point-uses-rayfall-name-prefix ()
  (with-temp-buffer
    (insert "(sym-na)")
    (backward-char)
    (cl-letf (((symbol-function 'rayfall--completion-candidates)
               (lambda (prefix)
                 (should (equal prefix "sym-na"))
                 '("sym-name"))))
      (should (equal (rayfall-completion-at-point)
                     '(2 8 ("sym-name") :exclusive no))))))

(ert-deftest rayfall-send-expression-prefers-active-region ()
  (with-temp-buffer
    (insert "first second")
    (let (sent-bounds)
      (cl-letf (((symbol-function 'use-region-p) (lambda () t))
                ((symbol-function 'region-beginning) (lambda () 7))
                ((symbol-function 'region-end) (lambda () 13))
                ((symbol-function 'rayfall-send-region)
                 (lambda (start end) (setq sent-bounds (cons start end))))
                ((symbol-function 'rayfall--expression-bounds)
                 (lambda () (ert-fail "Expression lookup should not run"))))
        (rayfall-send-expression)
        (should (equal sent-bounds '(7 . 13)))))))

(ert-deftest rayfall-completion-overlap-returns-nil ()
  (with-temp-buffer
    (let ((rayfall-repl-buffer (current-buffer)))
      (setq rayfall-repl--completion-request '(request))
      (cl-letf (((symbol-function 'rayfall--ensure-repl)
                 (lambda () 'test-process)))
        (should-not (rayfall--completion-candidates "sym"))))))

(ert-deftest rayfall-hides-internal-comint-output ()
  (with-temp-buffer
    (setq rayfall-repl--completion-request '(request))
    (let ((output (rayfall--hide-internal-output "candidate\n")))
      (should (eq (get-text-property 0 'invisible output)
                  rayfall--internal-output-invisibility)))
    (setq rayfall-repl--completion-request nil)
    (should (equal (rayfall--hide-internal-output "visible\n")
                   "visible\n"))))

(ert-deftest rayfall-insert-prompt-normalizes-prompt-only-line ()
  (with-temp-buffer
    (insert (propertize "‣ ‣ ‣ " 'field 'prompt))
    (let ((mark (copy-marker (point-max))))
      (cl-letf (((symbol-function 'rayfall--repl-live-p)
                 (lambda (&optional _buffer) t))
                ((symbol-function 'get-buffer-process)
                 (lambda (&optional _buffer) 'test-process))
                ((symbol-function 'process-mark)
                 (lambda (_process) mark)))
        (rayfall--insert-prompt)
        (should (equal (buffer-string) "‣ "))))))

(ert-deftest rayfall-completion-schedules-one-guarded-prompt ()
  (with-temp-buffer
    (setq rayfall-repl--completion-request '(request))
    (let (timer-callback)
      (cl-letf (((symbol-function 'rayfall--cancel-prompt-timer) #'ignore)
                ((symbol-function 'rayfall--complete-completion-request)
                 (lambda ()
                   (setq rayfall-repl--completion-request nil)
                   t))
                ((symbol-function 'run-at-time)
                 (lambda (_delay _repeat callback)
                   (setq timer-callback callback)
                   'test-timer)))
        (rayfall--prompt-after-output "completion output")
        (should rayfall-repl--completion-prompt-pending)
        (should timer-callback)
        (rayfall--prompt-after-output "late completion output")
        (should (eq rayfall-repl--prompt-timer 'test-timer))))))

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
                         (should
                          (string-suffix-p rayfall--repl-sentinel-command
                                           string)))))
              (rayfall-send-string (buffer-string) (point-max))
              (should (eq (marker-buffer
                           (cadr (with-current-buffer repl
                                   rayfall-repl--pending-eval)))
                          source)))))
      (kill-buffer source)
      (kill-buffer repl))))

(ert-deftest rayfall-rejects-unbalanced-source-before-sending ()
  (with-temp-buffer
    (set-syntax-table rayfall-mode-syntax-table)
    (insert "(+ 1 2")
    (let (sent)
      (cl-letf (((symbol-function 'rayfall-send-string)
                 (lambda (&rest _args) (setq sent t))))
        (should-error (rayfall-send-region (point-min) (point-max))
                      :type 'user-error)
        (should-not sent)))))

;;; rayfall-mode-test.el ends here
