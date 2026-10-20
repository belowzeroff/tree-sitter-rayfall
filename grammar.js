/**
 * @file Tree-sitter grammar for the Rayfall query language.
 * @author Rayforce contributors
 * @license MIT
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

module.exports = grammar({
  name: "rayfall",

  extras: $ => [
    /[\s\uFEFF\u2060\u200B]/,
    $.comment,
  ],

  rules: {
    source_file: $ => repeat($._expression),

    _expression: $ => choice(
      $.call,
      $.vector,
      $.dictionary,
      $.timestamp,
      $.timespan,
      $.date,
      $.time,
      $.null,
      $.float,
      $.integer,
      $.hexadecimal,
      $.boolean,
      $.string,
      $.character,
      $.quoted_symbol,
      $.keyword,
      $.identifier,
    ),

    call: $ => seq(
      "(",
      optional(seq(
        field("function", $._expression),
        repeat(field("argument", $._expression)),
      )),
      ")",
    ),

    vector: $ => seq("[", repeat(field("element", $._expression)), "]"),

    dictionary: $ => seq("{", repeat($.pair), "}"),

    pair: $ => seq(
      field("key", choice($.dictionary_key, $.string)),
      ":",
      field("value", $._expression),
    ),

    // Rayfall's dictionary parser accepts the same ASCII dispatch class as
    // names, except that dots are deliberately not valid in bare keys.
    dictionary_key: _ => token(/[A-Za-z0-9_!#$%&*+,\-\/.<=>?@^|~]+/),

    comment: _ => token(seq(";", /[^\n\r]*/)),

    boolean: _ => choice("true", "false"),

    null: _ => token(prec(7, /0N[hidtplfegn]?/)),

    hexadecimal: _ => token(prec(6, /-?0x[0-9A-Fa-f]+/)),

    timestamp: _ => token(prec(6,
      /[0-9]{4}\.[0-9]{2}\.[0-9]{2}D[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+/,
    )),

    // Signed nanosecond durations. Rayforce also accepts compact clock tails
    // and omitting seconds; value ranges are checked by the runtime.
    timespan: _ => token(prec(6, choice(
      /-?[0-9]{1,6}D(?:(?:[0-9]{2}:[0-9]{2}(?::[0-9]{2})?|[0-9]{1,6})(?:\.[0-9]+)?)?/,
      /-?0Wn/,
    ))),

    date: _ => token(prec(5, /[0-9]{4}\.[0-9]{2}\.[0-9]{2}/)),

    time: _ => token(prec(5, /-?[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?/)),

    float: _ => token(prec(4, choice(
      /-?[0-9]+\.[0-9]+(?:[eE][+-]?[0-9]+)?e?/,
      /-?[0-9]+[eE][+-]?[0-9]+e?/,
      /-?[0-9]+e/,
    ))),

    integer: _ => token(prec(3, /-?[0-9]+[hi]?/)),

    string: _ => token(seq(
      '"',
      repeat(choice(/[^"\\]/, /\\./)),
      '"',
    )),

    // Character literals are one byte, written as 'a' or with a C-style
    // escape. Octal escapes may contain one to three digits.
    character: _ => token(prec(3, choice(
      /'[^'\\]'/,
      /'\\(?:[0-7]{1,3}|.)'/,
    ))),

    // A bare tick is the empty symbol. Quoted symbols otherwise use the
    // parser's symbol-name character set and do not require a closing tick.
    quoted_symbol: _ => token(prec(2, /'[A-Za-z0-9_!#$%&*+,\-\/.<=>?@^|~]*/)),

    keyword: _ => token(seq(":", /[A-Za-z0-9_.\-\/?]+/)),

    identifier: _ => token(/[A-Za-z_!#$%&*+,\-\/.<=>?@^|~][A-Za-z0-9_!#$%&*+,\-\/.<=>?@^|~]*/),
  },
});
