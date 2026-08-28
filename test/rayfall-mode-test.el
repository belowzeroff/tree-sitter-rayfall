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

(ert-deftest rayfall-repl-default-command-parts ()
  (let ((rayfall-program "/tmp/rayforce")
        (rayfall-program-arguments '("-c" "2")))
    (should
     (equal (mapconcat #'shell-quote-argument
                       (cons rayfall-program
                             (append rayfall-program-arguments '("--interactive")))
                       " ")
            "/tmp/rayforce -c 2 --interactive"))))

;;; rayfall-mode-test.el ends here
