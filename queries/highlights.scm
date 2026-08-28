(comment) @comment

(string) @string
(character) @character
(quoted_symbol) @string.special.symbol
(keyword) @constant

[(integer) (float) (hexadecimal)] @number
[(date) (time) (timestamp)] @number
(null) @constant.builtin
(boolean) @constant.builtin

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

":" @punctuation.delimiter

(pair key: (dictionary_key) @property)

(identifier) @variable

(call function: (identifier) @function.call)

((call
  function: (identifier) @keyword)
 (#any-of? @keyword
  "do" "fn" "if" "let" "quote" "raise" "select" "set" "try" "update"))

((identifier) @operator
 (#any-of? @operator
  "+" "-" "*" "/" "%" "==" "!=" "<" "<=" ">" ">=" "&" "|"))
