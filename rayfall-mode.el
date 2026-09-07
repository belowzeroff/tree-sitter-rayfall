;;; rayfall-mode.el --- Tree-sitter mode and REPL for Rayfall -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rayforce contributors
;; Author: Rayforce contributors
;; Keywords: languages, processes
;; Package-Requires: ((emacs "29.1") (popup "0.5.9"))
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
(require 'cl-lib)
(require 'popup)
(require 'project)
(require 'subr-x)
(require 'xref)

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
point moves, the source buffer is edited, or another expression is evaluated.
The complete output remains available in the Rayfall REPL buffer."
  :type 'boolean
  :group 'rayfall)

(defcustom rayfall-repl-display-source-evaluations nil
  "Whether source evaluations and their results remain visible in the REPL.
This does not affect expressions entered directly in the REPL."
  :type 'boolean
  :group 'rayfall)

(defcustom rayfall-completion-timeout 1.0
  "Seconds to wait for `.repl.complete' to return candidates."
  :type 'number
  :group 'rayfall)

(defface rayfall-eval-result-face
  '((t :inherit tooltip :extend t))
  "Face used for inline Rayfall evaluation results."
  :group 'rayfall)

(defvar rayfall-repl-buffer nil
  "The active inferior Rayfall buffer.")

(defvar-local rayfall-repl--prompt-timer nil)
(defvar-local rayfall-repl--completion-prompt-pending nil)
(defvar-local rayfall-repl--source-buffer nil)
(defvar-local rayfall-repl--pending-eval nil)
(defvar-local rayfall-repl--completion-request nil)
(defvar-local rayfall-repl--completion-result nil)
(defvar-local rayfall--eval-result-overlay nil)
(defvar-local rayfall--eval-result-point nil)

(defconst rayfall--internal-output-invisibility 'rayfall-internal-output)

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
  (rx bos
      (or "+" "-" "*" "/" "%" "==" "!=" "<" "<=" ">" ">="
          "&" "|")
      eos))

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
   :language 'rayfall :feature 'function :override t
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

(defun rayfall--identifier-at-point ()
  "Return the Rayfall identifier at point, or nil."
  (let ((node (treesit-node-at
               (if (and (> (point) (point-min))
                        (or (eobp) (not (looking-at-p "[[:alnum:]_.-]"))))
                   (1- (point))
                 (point))
               'rayfall)))
    (when (and node (string= (treesit-node-type node) "identifier"))
      (treesit-node-text node t))))

(defun rayfall--definition-nodes (identifier)
  "Return definition nodes named IDENTIFIER in the current buffer."
  (let ((root (treesit-buffer-root-node 'rayfall)) nodes)
    (dolist (capture
             (treesit-query-capture
              root
              `((call
                 function: (identifier) @_binder
                 argument: (identifier) @definition
                 (:match ,(rx bos (or "set" "let") eos) @_binder))
                (call
                 function: (identifier) @_fn
                 argument: (vector (identifier) @definition)
                 (:equal @_fn "fn")))))
      (when (and (eq (car capture) 'definition)
                 (equal (treesit-node-text (cdr capture) t) identifier))
        (push (cdr capture) nodes)))
    (nreverse nodes)))

(defun rayfall--definition-xrefs-in-buffer (identifier buffer &optional file)
  "Find IDENTIFIER definitions in BUFFER, optionally attributing them to FILE."
  (with-current-buffer buffer
    (mapcar
     (lambda (node)
       (let ((position (treesit-node-start node)))
         (xref-make
          identifier
          (if file
              (save-excursion
                (goto-char position)
                (xref-make-file-location
                 file (line-number-at-pos) (current-column)))
            (xref-make-buffer-location buffer position)))))
     (rayfall--definition-nodes identifier))))

(defun rayfall--project-rayfall-files ()
  "Return Rayfall files in the current project, excluding the current file."
  (when-let ((project (project-current nil)))
    (let ((current (and buffer-file-name (file-truename buffer-file-name))))
      (seq-filter
       (lambda (file)
         (and (string-match-p "\\.rfl\\'" file)
              (not (and current (equal (file-truename file) current)))))
       (project-files project)))))

(defun rayfall--xref-definitions (identifier)
  "Return Xref definitions for IDENTIFIER in the buffer and project."
  (let ((xrefs (rayfall--definition-xrefs-in-buffer
                identifier (current-buffer) buffer-file-name)))
    (dolist (file (rayfall--project-rayfall-files))
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents file)
            (delay-mode-hooks (rayfall-mode))
            (setq xrefs
                  (nconc xrefs
                         (rayfall--definition-xrefs-in-buffer
                          identifier (current-buffer) file))))
        (error nil)))
    xrefs))

(defun rayfall-xref-backend ()
  "Return the Rayfall Xref backend for `rayfall-mode'."
  'rayfall)

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql rayfall)))
  (rayfall--identifier-at-point))

(cl-defmethod xref-backend-definitions ((_backend (eql rayfall)) identifier)
  (rayfall--xref-definitions identifier))

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

(defun rayfall--hide-internal-output (output)
  "Make internal evaluation or completion OUTPUT invisible to Comint."
  (if (or rayfall-repl--completion-request
          (and rayfall-repl--pending-eval
               (not rayfall-repl-display-source-evaluations)))
      (propertize output 'invisible rayfall--internal-output-invisibility)
    output))

(defun rayfall--clear-eval-result (&rest _ignored)
  "Remove the inline evaluation result in the current source buffer."
  (when rayfall--eval-result-overlay
    (ignore-errors (popup-delete rayfall--eval-result-overlay)))
  (setq rayfall--eval-result-overlay nil)
  (setq rayfall--eval-result-point nil)
  (remove-hook 'after-change-functions #'rayfall--clear-eval-result t)
  (remove-hook 'post-command-hook
               #'rayfall--clear-eval-result-after-point-move t))

(defun rayfall--clear-eval-result-after-point-move ()
  "Remove the inline evaluation result after point moves."
  (when (and rayfall--eval-result-point
             (/= (point) rayfall--eval-result-point))
    (rayfall--clear-eval-result)))

(defun rayfall--display-eval-result (buffer position result)
  "Display RESULT in BUFFER after POSITION as virtual text."
  (when (and rayfall-display-eval-results
             (buffer-live-p buffer)
             (marker-position position)
             (not (string-empty-p result)))
    (with-current-buffer buffer
      (rayfall--clear-eval-result)
      (let* ((lines
              (mapcar
               (lambda (line)
                 (concat (propertize " " 'face '(:background inherit))
                         line " \n"))
               (split-string result "\n" nil)))
             (display-result (string-trim-right (apply #'concat lines))))
        (setq rayfall--eval-result-overlay
              (popup-tip display-result
                         ;; `popup-create' retains its point argument.  Do not
                         ;; give it the pending evaluation marker, which is
                         ;; invalidated as soon as the result is displayed.
                         :point (marker-position position)
                         :around nil
                         :face 'rayfall-eval-result-face
                         :nowait t
                         :nostrip t)))
      (setq rayfall--eval-result-point (point))
      (add-hook 'after-change-functions #'rayfall--clear-eval-result nil t)
      (add-hook 'post-command-hook
                #'rayfall--clear-eval-result-after-point-move nil t))))

(defun rayfall--finish-pending-eval (&optional output-end)
  "Capture process output through OUTPUT-END and show it in the source buffer.
When OUTPUT-END is nil, use the current process mark."
  (when rayfall-repl--pending-eval
    (pcase-let ((`(,source ,source-position ,output-start ,_delimiter
                            ,_repl-start)
                 rayfall-repl--pending-eval))
      (setq rayfall-repl--pending-eval nil)
      (let* ((process (get-buffer-process (current-buffer)))
             (output-end (or output-end
                             (and process (process-mark process))))
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

(defun rayfall--complete-pending-eval ()
  "Finish the pending evaluation if its completion delimiter has arrived."
  (when rayfall-repl--pending-eval
    (pcase-let ((`(,_source ,_source-position ,output-start ,delimiter
                             ,repl-start)
                 rayfall-repl--pending-eval))
      (let ((process (get-buffer-process (current-buffer)))
            delimiter-start delimiter-end)
        (when (and process (marker-position output-start))
          (save-excursion
            (goto-char output-start)
            (when (re-search-forward
                   (concat "^" (regexp-quote delimiter) "\r?\n")
                   (process-mark process) t)
              (setq delimiter-start (match-beginning 0)
                    delimiter-end (match-end 0))))
          (when delimiter-start
            (rayfall--finish-pending-eval delimiter-start)
            (let ((inhibit-read-only t))
              (delete-region (if rayfall-repl-display-source-evaluations
                                 delimiter-start
                               repl-start)
                             delimiter-end))
            (set-marker repl-start nil)
            t))))))

(defun rayfall--parse-completions (output)
  "Parse the symbol vector in Rayforce completion OUTPUT."
  (let ((text (string-trim output)))
    (if (and (string-prefix-p "[" text)
             (string-suffix-p "]" text))
        (mapcar (lambda (candidate)
                  (string-remove-prefix "'" candidate))
                (split-string (substring text 1 -1) "[[:space:]]+" t))
      nil)))

(defun rayfall--complete-completion-request ()
  "Consume a completed `.repl.complete' response from the REPL buffer."
  (when rayfall-repl--completion-request
    (pcase-let ((`(,output-start ,delimiter)
                 rayfall-repl--completion-request))
      (let ((process (get-buffer-process (current-buffer)))
            delimiter-start delimiter-end)
        (when (and process (marker-position output-start))
          (save-excursion
            (goto-char output-start)
            (when (re-search-forward
                   (concat "^" (regexp-quote delimiter) "\r?\n")
                   (process-mark process) t)
              (setq delimiter-start (match-beginning 0)
                    delimiter-end (match-end 0))))
          (when delimiter-start
            (setq rayfall-repl--completion-result
                  (rayfall--parse-completions
                   (ansi-color-filter-apply
                    (buffer-substring-no-properties
                     output-start delimiter-start))))
            (setq rayfall-repl--completion-request nil)
            (let ((inhibit-read-only t))
              (delete-region output-start delimiter-end))
            (set-marker output-start nil)
            t))))))

(defun rayfall--insert-prompt ()
  "Insert a synthetic Rayfall prompt at the process mark."
  (when (rayfall--repl-live-p (current-buffer))
    (let* ((process (get-buffer-process (current-buffer)))
           (mark (process-mark process))
           (inhibit-read-only t)
           (inhibit-field-text-motion t)
           (line (buffer-substring-no-properties
                  (save-excursion (goto-char mark) (line-beginning-position))
                  mark)))
      (unless (equal line "‣ ")
        (goto-char mark)
        ;; Hidden completion traffic can leave no prompt or several prompts,
        ;; depending on how process markers moved while its output was erased.
        ;; Normalize a prompt-only line instead of appending indefinitely.
        (when (string-match-p (rx bos (* "‣ ") eos) line)
          (delete-region (line-beginning-position) mark))
        (insert-before-markers
         (propertize "‣ " 'font-lock-face 'comint-highlight-prompt
                     'field 'prompt 'rear-nonsticky t))))))

(defun rayfall--prompt-after-output (_output)
  "Debounce insertion of the synthetic prompt after process output."
  (cond
   (rayfall-repl--completion-prompt-pending)
   (rayfall-repl--completion-request
    (when (rayfall--complete-completion-request)
      (let ((buffer (current-buffer)))
        (setq rayfall-repl--completion-prompt-pending t
              rayfall-repl--prompt-timer
              (run-at-time
               rayfall-repl-prompt-delay nil
               (lambda ()
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (setq rayfall-repl--prompt-timer nil
                           rayfall-repl--completion-prompt-pending nil)
                     (rayfall--insert-prompt)))))))))
   (t
    (rayfall--cancel-prompt-timer)
    (when (or (not rayfall-repl--pending-eval)
              (rayfall--complete-pending-eval))
      (let ((buffer (current-buffer)))
        (setq rayfall-repl--prompt-timer
              (run-at-time
               rayfall-repl-prompt-delay nil
               (lambda ()
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (setq rayfall-repl--prompt-timer nil)
                     (rayfall--insert-prompt)))))))))))

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
  (add-to-invisibility-spec rayfall--internal-output-invisibility)
  (add-hook 'comint-preoutput-filter-functions
            #'rayfall--hide-internal-output nil t)
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

(defun rayfall--completion-candidates (prefix)
  "Return live Rayforce completion candidates for PREFIX."
  (let ((process (rayfall--ensure-repl)))
    (with-current-buffer rayfall-repl-buffer
      (unless (or rayfall-repl--pending-eval
                  rayfall-repl--completion-request)
        (rayfall--cancel-prompt-timer)
        (let* ((output-start (copy-marker (process-mark process)))
               (delimiter (format "__rayfall_complete_%x_%x__"
                                  (emacs-pid) (random most-positive-fixnum)))
               (deadline (+ (float-time) rayfall-completion-timeout)))
          (setq rayfall-repl--completion-result nil
                rayfall-repl--completion-request
                (list output-start delimiter))
          (comint-send-string
           process
           (format "(println (.repl.complete %S))\n(println \"%s\")\n"
                   prefix delimiter))
          (while (and rayfall-repl--completion-request
                      (< (float-time) deadline))
            (accept-process-output process 0.05))
          ;; Company may time out at the same instant the delimiter enters the
          ;; buffer, before the output hook consumes it.  Check once directly.
          (when rayfall-repl--completion-request
            (rayfall--complete-completion-request))
          ;; Never let a failed or partial completion block later evaluation.
          (when rayfall-repl--completion-request
            (set-marker (car rayfall-repl--completion-request) nil)
            (setq rayfall-repl--completion-request nil))
          rayfall-repl--completion-result)))))

(defun rayfall-completion-at-point ()
  "Complete the Rayfall name at point using the live Rayforce session."
  (let ((end (point))
        (start (save-excursion
                 (skip-chars-backward "A-Za-z0-9_!#$%&*+,-./:<=>?@^|~")
                 (point))))
    (when (< start end)
      (let* ((prefix (buffer-substring-no-properties start end))
             (candidates (rayfall--completion-candidates prefix)))
        (when candidates
          (list start end candidates :exclusive 'no))))))

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
      (when rayfall-repl--pending-eval
        (user-error "A Rayfall evaluation is still in progress"))
      (when rayfall-repl--completion-request
        (user-error "A Rayfall completion request is still in progress"))
      (let* ((process (get-buffer-process (current-buffer)))
             (mark (process-mark process))
             (repl-start (marker-position mark))
             (delimiter (format "__rayfall_emacs_%x_%x__"
                                (emacs-pid) (random most-positive-fixnum)))
             (inhibit-read-only t))
        (goto-char mark)
        (insert-before-markers
         (if rayfall-repl-display-source-evaluations
             string
           (propertize string
                       'invisible rayfall--internal-output-invisibility)))
        (unless (string-suffix-p "\n" string)
          (insert-before-markers
           (if rayfall-repl-display-source-evaluations
               "\n"
             (propertize "\n"
                         'invisible rayfall--internal-output-invisibility))))
        (when result-position
          (setq rayfall-repl--pending-eval
                (list source
                      source-position
                      (copy-marker mark)
                      delimiter
                      (copy-marker repl-start))))
        (comint-send-string process
                            (concat (string-trim-right string) "\n"
                                    (and result-position
                                         (format "(println \"%s\")\n"
                                                 delimiter))))))))

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
  (add-hook 'completion-at-point-functions
            #'rayfall-completion-at-point nil t)
  (add-hook 'xref-backend-functions #'rayfall-xref-backend nil t)
  (treesit-major-mode-setup))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.rfl\\'" . rayfall-mode))

(provide 'rayfall-mode)
;;; rayfall-mode.el ends here
