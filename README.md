# tree-sitter-rayfall

A [Tree-sitter](https://tree-sitter.github.io/tree-sitter/) grammar for the
Rayfall query language. It follows Rayforce's
[documented syntax](https://github.com/RayforceDB/rayforce/blob/main/docs/docs/language/syntax.md)
and [runtime parser](https://github.com/RayforceDB/rayforce/blob/main/src/lang/parse.c).

The grammar includes queries for highlighting, indentation, and local
bindings. The stable named nodes (`call`, `vector`, `dictionary`, `pair`, and
the literal nodes) are used by the included native Tree-sitter Emacs mode,
[`rayfall-mode.el`](rayfall-mode.el).

## Develop and test

Tree-sitter CLI 0.25 or newer and Node.js are required:

```sh
npm install
npm run generate
npm test
```

Generated parser sources are committed so editor integrations can compile the
grammar without requiring Node.js or the Tree-sitter CLI. They use language
ABI 14 for compatibility with the Tree-sitter versions commonly used by Emacs
29 and newer.

Rayfall source files conventionally use the `.rfl` extension.

For Emacs 29 or newer, the grammar can be registered directly from the
Rayforce repository:

```elisp
(add-to-list 'treesit-language-source-alist
             '(rayfall "https://github.com/vbmithr/tree-sitter-rayfall"))
(treesit-install-language-grammar 'rayfall)
```

The mode checks availability with `(treesit-language-available-p 'rayfall)`.

## Emacs mode

After installing the grammar, put this directory on `load-path` and load the
mode:

```elisp
(add-to-list 'load-path "/path/to/tree-sitter-rayfall")
(require 'rayfall-mode)
(setq rayfall-program "/path/to/rayforce/rayforce")
```

Files ending in `.rfl` then open in `rayfall-mode`. The main commands are:

| Key | Command |
|---|---|
| `C-c C-z` | Start or display the Rayfall REPL |
| `C-c C-e` / `C-M-x` | Send the outermost expression at point |
| `C-c C-j` | Send the current line |
| `C-c C-r` | Send the active region |
| `C-c C-b` | Send the whole buffer |
| `C-c C-q` | Switch to the REPL |

The inferior process runs through a pipe because Rayforce enables its own raw
terminal editor on a PTY. Comint therefore owns input editing and history,
while the Rayforce process remains alive and preserves definitions between
evaluations. Results sent with the evaluation commands are also displayed as
virtual text immediately after the evaluated expression; they remain in the
REPL and disappear from the source buffer on the next edit or evaluation.
Customize `rayfall-display-eval-results` to disable the inline display and
`rayfall-eval-result-face` to change its appearance.

Use a prefix argument with `M-x rayfall-repl` to edit the launch
command for a particular session. Customize `rayfall-program` and
`rayfall-program-arguments` for persistent changes.
