((call
  function: (identifier) @_fn
  argument: (identifier) @local.definition)
 (#any-of? @_fn "let" "set"))

((call
  function: (identifier) @_fn
  argument: (vector (identifier) @local.definition))
 (#eq? @_fn "fn"))

(identifier) @local.reference
