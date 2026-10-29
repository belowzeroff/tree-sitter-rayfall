(comment) @comment

(string) @string
(character) @character
(quoted_symbol) @string.special.symbol
(keyword) @constant

[(integer) (float) (hexadecimal)] @number
[(date) (time) (timestamp) (timespan)] @number
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
  "do" "fn" "if" "let" "quote" "raise" "return" "select" "set" "times" "try"
  "update" "while"))

((identifier) @operator
 (#any-of? @operator
  "+" "-" "*" "/" "%" "==" "!=" "<" "<=" ">" ">=" "&" "|"))
