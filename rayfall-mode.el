;;; rayfall-mode.el --- Tree-sitter mode and REPL for Rayfall -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rayforce contributors
;; Author: Rayforce contributors
;; Keywords: languages, processes
;; Package-Requires: ((emacs "29.1"))
;; Version: 0.1.0
;; URL: https://github.com/vbmithr/tree-sitter-rayfall

;;; Commentary:

;; A Tree-sitter major mode for Rayfall, with a Comint REPL backed by the
;; `rayforce' executable.  Use `M-x rayfall-repl' to start the interpreter,
;; then C-c C-e/C-r/C-b to send an expression, region, or buffer.

;;; Code:

(require 'comint)
(require 'treesit)
(require 'ansi-color)
(require 'subr-x)

(defgroup rayfall nil
  "Editing and evaluating Rayfall code."
  :group 'languages)

(defcustom rayfall-program "rayforce"
  "Rayforce executable used for the inferior Rayfall process."
  :type 'file
  :group 'rayfall)

(defcustom rayfall-program-arguments nil
  "Arguments passed to `rayfall-program'.
The mode adds `--interactive' so a listener configuration cannot make the
pipe-backed subprocess enter server-only mode."
  :type '(repeat string)
  :group 'rayfall)

(defcustom rayfall-indent-offset 2
  "Number of columns added when indenting a nested Rayfall form."
  :type 'integer
  :safe #'integerp
  :group 'rayfall)

(defcustom rayfall-repl-buffer-name "*Rayfall*"
  "Default name of the inferior Rayfall buffer."
  :type 'string
  :group 'rayfall)

(defcustom rayfall-repl-prompt-delay 0.04
  "Idle seconds after process output before displaying the next prompt.
Rayforce deliberately emits no prompts in pipe mode, so the Comint frontend
adds one after the output stream becomes idle."
  :type 'number
  :group 'rayfall)

(defcustom rayfall-display-eval-results t
  "Whether to display evaluation results inline in Rayfall source buffers.
The result is shown after the expression as virtual text and is removed when
the source buffer is edited or another expression is evaluated.  The complete
output remains available in the Rayfall REPL buffer."
  :type 'boolean
  :group 'rayfall)

(defface rayfall-eval-result-face
  '((t :inherit shadow))
  "Face used for inline Rayfall evaluation results."
  :group 'rayfall)

(defvar rayfall-repl-buffer nil
  "The active inferior Rayfall buffer.")

(defvar-local rayfall-repl--prompt-timer nil)
(defvar-local rayfall-repl--source-buffer nil)
(defvar-local rayfall-repl--pending-eval nil)
(defvar-local rayfall--eval-result-overlay nil)

(defvar rayfall-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?\; "<" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?\\ "\\" table)
    (modify-syntax-entry ?' "." table)
    (modify-syntax-entry ?\( "()" table)
    (modify-syntax-entry ?\) ")(" table)
    (modify-syntax-entry ?\[ "(]" table)
    (modify-syntax-entry ?\] ")[" table)
    (modify-syntax-entry ?\{ "(}" table)
    (modify-syntax-entry ?\} "){" table)
    table)
  "Syntax table used by `rayfall-mode'.")

(defconst rayfall--special-forms
  (rx bos (or "do" "fn" "if" "let" "quote" "raise" "select" "set"
              "try" "update") eos))

(defconst rayfall--operators
  (regexp-opt '("+" "-" "*" "/" "%" "==" "!=" "<" "<=" ">" ">="
                "&" "|") t))

(defvar rayfall--treesit-font-lock-settings
  (treesit-font-lock-rules
   :language 'rayfall :feature 'comment
   '((comment) @font-lock-comment-face)
   :language 'rayfall :feature 'string
   '((string) @font-lock-string-face
     (character) @font-lock-string-face
     (quoted_symbol) @font-lock-constant-face)
   :language 'rayfall :feature 'literal
   '((integer) @font-lock-number-face
     (float) @font-lock-number-face
     (hexadecimal) @font-lock-number-face
     (date) @font-lock-number-face
     (time) @font-lock-number-face
     (timestamp) @font-lock-number-face
     (boolean) @font-lock-constant-face
     (null) @font-lock-constant-face
     (keyword) @font-lock-constant-face)
   :language 'rayfall :feature 'property
   '((pair key: (dictionary_key) @font-lock-property-name-face))
   :language 'rayfall :feature 'identifier
   '((identifier) @font-lock-variable-use-face)
   :language 'rayfall :feature 'function
   '((call function: (identifier) @font-lock-function-call-face))
   :language 'rayfall :feature 'definition :override t
   `((call
      function: (identifier) @_form
      argument: (identifier) @font-lock-variable-name-face
      (:match ,(rx bos (or "set" "let") eos) @_form)))
   :language 'rayfall :feature 'keyword :override t
   `(((identifier) @font-lock-keyword-face
      (:match ,rayfall--special-forms @font-lock-keyword-face)))
   :language 'rayfall :feature 'operator :override t
   `(((identifier) @font-lock-operator-face
      (:match ,rayfall--operators @font-lock-operator-face)))
   :language 'rayfall :feature 'bracket
   '(["(" ")" "[" "]" "{" "}"] @font-lock-bracket-face
     ":" @font-lock-delimiter-face))
  "Tree-sitter font-lock rules for Rayfall.")

(defvar rayfall--treesit-indent-rules
  `((rayfall
     ((node-is ")") parent-bol 0)
     ((node-is "]") parent-bol 0)
     ((node-is "}") parent-bol 0)
     ((parent-is "call") parent-bol ,rayfall-indent-offset)
     ((parent-is "vector") parent-bol ,rayfall-indent-offset)
     ((parent-is "dictionary") parent-bol ,rayfall-indent-offset)
     ((parent-is "pair") parent-bol ,rayfall-indent-offset)
     (no-node parent-bol 0)))
  "Tree-sitter indentation rules for Rayfall.")

(defun rayfall--require-grammar ()
  "Signal a helpful error unless the Rayfall grammar is installed."
  (unless (treesit-ready-p 'rayfall t)
    (user-error
     (concat "Rayfall Tree-sitter grammar is unavailable; install it with "
             "M-x treesit-install-language-grammar after adding its source "
             "to `treesit-language-source-alist'"))))

(defun rayfall--node-at-point ()
  "Return the outermost Rayfall expression containing point."
  (let ((node (treesit-node-at (point) 'rayfall)))
    (while (and (treesit-node-parent node)
                (not (string= (treesit-node-type (treesit-node-parent node))
                              "source_file")))
      (setq node (treesit-node-parent node)))
    node))

(defun rayfall--expression-bounds ()
  "Return bounds of the outermost expression at point."
  (let ((node (rayfall--node-at-point)))
    (unless (and node (not (string= (treesit-node-type node) "source_file")))
      (user-error "No Rayfall expression at point"))
    ;; Tree-sitter accepts adjacent top-level tokens as separate forms, while
    ;; the Rayforce reader treats them as one malformed token (for example,
    ;; `0X').  Include siblings with no separating whitespace so evaluation
    ;; reports the same syntax/name error that Rayforce would report for the
    ;; text the user sees as one expression.
    (let ((start-node node)
          (end-node node)
          sibling)
      (while (and (setq sibling (treesit-node-prev-sibling start-node t))
                  (= (treesit-node-end sibling)
                     (treesit-node-start start-node)))
        (setq start-node sibling))
      (while (and (setq sibling (treesit-node-next-sibling end-node t))
                  (= (treesit-node-start sibling)
                     (treesit-node-end end-node)))
        (setq end-node sibling))
      (cons (treesit-node-start start-node) (treesit-node-end end-node)))))

(defun rayfall--imenu-index ()
  "Return an Imenu index of top-level `(set NAME (fn ...))' definitions."
  (let ((root (treesit-buffer-root-node 'rayfall)) entries)
    (dolist (capture
             (treesit-query-capture
              root
              '((call
                 function: (identifier) @_set
                 argument: (identifier) @name
                 argument: (call function: (identifier) @_fn)
                 (:equal @_set "set")
                 (:equal @_fn "fn")))))
      (when (eq (car capture) 'name)
        (let ((node (cdr capture)))
          (push (cons (treesit-node-text node t)
                      (copy-marker (treesit-node-start node)))
                entries))))
    (nreverse entries)))

(defvar rayfall-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-z") #'rayfall-repl)
    (define-key map (kbd "C-c C-q") #'rayfall-switch-to-repl)
    (define-key map (kbd "C-c C-e") #'rayfall-send-expression)
    (define-key map (kbd "C-M-x") #'rayfall-send-expression)
    (define-key map (kbd "C-c C-j") #'rayfall-send-line)
    (define-key map (kbd "C-c C-r") #'rayfall-send-region)
    (define-key map (kbd "C-c C-b") #'rayfall-send-buffer)
    map)
  "Keymap for `rayfall-mode'.")

(defvar rayfall-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map comint-mode-map)
    (define-key map (kbd "C-c C-z") #'rayfall-switch-to-source)
    map)
  "Keymap for `rayfall-repl-mode'.")

(defun rayfall--repl-live-p (&optional buffer)
  "Return non-nil when BUFFER, or the active REPL, has a live process."
  (let ((buffer (or buffer rayfall-repl-buffer)))
    (and (buffer-live-p buffer) (comint-check-proc buffer))))

(defun rayfall--cancel-prompt-timer ()
  "Cancel the current REPL buffer's pending synthetic prompt."
  (when (timerp rayfall-repl--prompt-timer)
    (cancel-timer rayfall-repl--prompt-timer))
  (setq rayfall-repl--prompt-timer nil))

(defun rayfall--clear-eval-result (&rest _ignored)
  "Remove the inline evaluation result in the current source buffer."
  (when (overlayp rayfall--eval-result-overlay)
    (delete-overlay rayfall--eval-result-overlay))
  (setq rayfall--eval-result-overlay nil)
  (remove-hook 'after-change-functions #'rayfall--clear-eval-result t))

(defun rayfall--display-eval-result (buffer position result)
  "Display RESULT in BUFFER after POSITION as virtual text."
  (when (and rayfall-display-eval-results
             (buffer-live-p buffer)
             (marker-position position)
             (not (string-empty-p result)))
    (with-current-buffer buffer
      (rayfall--clear-eval-result)
      (let ((overlay (make-overlay position position buffer)))
        (overlay-put overlay 'after-string
                     (propertize (concat "  ⇒ " result)
                                 'face 'rayfall-eval-result-face))
        (setq rayfall--eval-result-overlay overlay)
        (add-hook 'after-change-functions #'rayfall--clear-eval-result nil t)))))

(defun rayfall--finish-pending-eval ()
  "Capture completed process output and show it in the source buffer."
  (when rayfall-repl--pending-eval
    (pcase-let ((`(,source ,source-position ,output-start)
                 rayfall-repl--pending-eval))
      (setq rayfall-repl--pending-eval nil)
      (let* ((process (get-buffer-process (current-buffer)))
             (output-end (and process (process-mark process)))
             (result
              (and output-end
                   (marker-position output-start)
                   (string-trim
                    (ansi-color-filter-apply
                     (buffer-substring-no-properties output-start output-end))))))
        (when result
          (rayfall--display-eval-result source source-position result)))
      (set-marker source-position nil)
      (set-marker output-start nil))))

(defun rayfall--insert-prompt ()
  "Insert a synthetic Rayfall prompt at the process mark."
  (when (rayfall--repl-live-p (current-buffer))
    (let* ((process (get-buffer-process (current-buffer)))
           (mark (process-mark process))
           (inhibit-read-only t))
      (unless (save-excursion
                (goto-char mark)
                (equal (buffer-substring-no-properties
                        (line-beginning-position) mark)
                       "‣ "))
        (goto-char mark)
        (insert-before-markers
         (propertize "‣ " 'font-lock-face 'comint-highlight-prompt
                     'field 'prompt 'rear-nonsticky t))))))

(defun rayfall--prompt-after-output (_output)
  "Debounce insertion of the synthetic prompt after process output."
  (rayfall--cancel-prompt-timer)
  (let ((buffer (current-buffer)))
    (setq rayfall-repl--prompt-timer
          (run-at-time
           rayfall-repl-prompt-delay nil
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq rayfall-repl--prompt-timer nil)
                 (rayfall--finish-pending-eval)
                 (rayfall--insert-prompt))))))))

(defun rayfall--repl-sentinel (process event)
  "Record PROCESS termination described by EVENT and save history."
  (when-let ((buffer (process-buffer process)))
    (with-current-buffer buffer
      (rayfall--cancel-prompt-timer)
      (comint-write-input-ring)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format "\nProcess %s %s" (process-name process) event))))))

;;;###autoload
(define-derived-mode rayfall-repl-mode comint-mode "Rayfall-REPL"
  "Major mode for interacting with an inferior Rayfall process."
  :group 'rayfall
  (setq-local comint-prompt-regexp "^‣ ")
  (setq-local comint-use-prompt-regexp t)
  (setq-local comint-process-echoes nil)
  (setq-local comint-input-ring-file-name
              (expand-file-name "rayfall-history" user-emacs-directory))
  (setq-local comment-start ";")
  (setq-local comment-end "")
  (add-hook 'comint-output-filter-functions #'ansi-color-process-output nil t)
  (add-hook 'comint-output-filter-functions #'rayfall--prompt-after-output nil t)
  (ignore-errors (comint-read-input-ring t)))

;;;###autoload
(defun rayfall-repl (&optional prompt-for-command)
  "Start or display an inferior Rayfall process.
With prefix argument PROMPT-FOR-COMMAND, read the executable and arguments
from the minibuffer.  The new process becomes `rayfall-repl-buffer'."
  (interactive "P")
  (let* ((default-command
           (mapconcat #'shell-quote-argument
                      (cons rayfall-program
                            (append rayfall-program-arguments
                                    '("--interactive")))
                      " "))
         (command (if prompt-for-command
                      (read-shell-command "Run Rayfall: " default-command)
                    default-command))
         (argv (split-string-and-unquote command))
         (program (car argv))
         (args (cdr argv))
         (buffer (get-buffer-create rayfall-repl-buffer-name)))
    (unless (and program (not (string-empty-p program)))
      (user-error "Rayfall command is empty"))
    (setq rayfall-repl-buffer buffer)
    (unless (rayfall--repl-live-p buffer)
      (with-current-buffer buffer
        (rayfall-repl-mode)
        ;; A pipe selects Rayforce's plain line protocol.  A PTY would enable
        ;; Rayforce's own raw-terminal editor, which conflicts with Comint.
        (let ((process-connection-type nil))
          (apply #'make-comint-in-buffer "Rayfall" buffer program nil args))
        (set-process-sentinel (get-buffer-process buffer)
                              #'rayfall--repl-sentinel)
        (rayfall--insert-prompt)))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    (get-buffer-process buffer)))

(defun rayfall--ensure-repl ()
  "Return the active process, starting Rayfall when necessary."
  (or (and (rayfall--repl-live-p) (get-buffer-process rayfall-repl-buffer))
      (rayfall-repl)))

(defun rayfall-send-string (string &optional result-position)
  "Send STRING to the active inferior Rayfall process.
When RESULT-POSITION is non-nil, display the resulting output there."
  (unless (and (stringp string) (not (string-empty-p (string-trim string))))
    (user-error "Nothing to send"))
  (let ((source (current-buffer))
        (source-position (and result-position
                              (copy-marker result-position))))
    (rayfall--ensure-repl)
    (with-current-buffer rayfall-repl-buffer
      (setq rayfall-repl--source-buffer source)
      (rayfall--cancel-prompt-timer)
      ;; Output is delimited by the same idle period used for the synthetic
      ;; prompt.  Complete an older request before installing new markers.
      (rayfall--finish-pending-eval)
      (let* ((process (get-buffer-process (current-buffer)))
             (mark (process-mark process))
             (inhibit-read-only t))
        (goto-char mark)
        (insert-before-markers string)
        (unless (string-suffix-p "\n" string)
          (insert-before-markers "\n"))
        (when (and rayfall-display-eval-results result-position)
          (setq rayfall-repl--pending-eval
                (list source
                      source-position
                      (copy-marker mark)))))
      (comint-send-string (get-buffer-process (current-buffer))
                          (concat (string-trim-right string) "\n")))))

(defun rayfall-send-region (start end)
  "Send the region between START and END to inferior Rayfall."
  (interactive "r")
  (rayfall--clear-eval-result)
  (rayfall-send-string (buffer-substring-no-properties start end) end)
  (setq deactivate-mark t))

(defun rayfall-send-expression ()
  "Send the outermost expression at point to inferior Rayfall."
  (interactive)
  (pcase-let ((`(,start . ,end) (rayfall--expression-bounds)))
    (rayfall-send-region start end)))

(defun rayfall-send-line ()
  "Send the current line to inferior Rayfall."
  (interactive)
  (rayfall-send-region (line-beginning-position) (line-end-position)))

(defun rayfall-send-buffer ()
  "Send the entire current buffer to inferior Rayfall."
  (interactive)
  (rayfall-send-region (point-min) (point-max)))

(defun rayfall-switch-to-repl ()
  "Display the active Rayfall REPL, starting it when necessary."
  (interactive)
  (rayfall--ensure-repl)
  (pop-to-buffer rayfall-repl-buffer))

(defun rayfall-switch-to-source ()
  "Return from the REPL to the most recent source buffer."
  (interactive)
  (unless (buffer-live-p rayfall-repl--source-buffer)
    (user-error "No Rayfall source buffer associated with this REPL"))
  (pop-to-buffer rayfall-repl--source-buffer))

;;;###autoload
(define-derived-mode rayfall-mode prog-mode "Rayfall"
  "Major mode for editing Rayfall source using Tree-sitter."
  :group 'rayfall
  :syntax-table rayfall-mode-syntax-table
  (rayfall--require-grammar)
  (treesit-parser-create 'rayfall)
  (setq-local comment-start ";")
  (setq-local comment-start-skip ";+[ \t]*")
  (setq-local comment-end "")
  (setq-local treesit-font-lock-feature-list
              '((comment string)
                (literal property)
                (bracket identifier function definition keyword operator)))
  (setq-local treesit-font-lock-settings rayfall--treesit-font-lock-settings)
  (setq-local treesit-simple-indent-rules rayfall--treesit-indent-rules)
  (setq-local indent-tabs-mode nil)
  (setq-local imenu-create-index-function #'rayfall--imenu-index)
  (treesit-major-mode-setup))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.rfl\\'" . rayfall-mode))

(provide 'rayfall-mode)
;;; rayfall-mode.el ends here
