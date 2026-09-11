require "rouge"

# Rendering Dockerfiles and scripts. Review reads line by line, so both the
# highlighting and the diff are lined up to match.
module CodeHelper
  LEXERS = {
    dockerfile: Rouge::Lexers::Docker,
    ruby: Rouge::Lexers::Ruby,
    plain: Rouge::Lexers::PlainText
  }.freeze

  # Some tokens span lines (heredocs, block comments), so it is the token stream
  # that gets split on newlines, not the rendered output
  def highlight_lines(text, syntax: :plain)
    formatter = Rouge::Formatters::HTML.new
    lexer = LEXERS.fetch(syntax, LEXERS[:plain]).new
    lines = [ [] ]

    lexer.lex(text.to_s).each do |token, value|
      value.split("\n", -1).each_with_index do |part, index|
        lines << [] if index.positive?
        lines.last << [ token, part ] unless part.empty?
      end
    end

    # A trailing newline is not itself a line
    lines.pop if lines.size > 1 && lines.last.empty?
    lines.map { |tokens| formatter.format(tokens).html_safe }
  end

  # A line diff against the previous revision. Dockerfiles are small, so a plain
  # LCS is enough. It returns a sequence of [:same | :add | :del, highlighted line].
  def line_diff(before, after, syntax: :plain)
    old_raw = split_lines(before)
    new_raw = split_lines(after)
    old_html = highlight_lines(before, syntax:)
    new_html = highlight_lines(after, syntax:)

    walk_lcs(old_raw, new_raw).map do |kind, old_index, new_index|
      case kind
      when :del then [ :del, old_html[old_index] ]
      else [ kind, new_html[new_index] ]
      end
    end
  end

  private

  # A trailing newline is not itself a line (kept in step with highlight_lines)
  def split_lines(text)
    lines = text.to_s.split("\n", -1)
    lines.pop if lines.size > 1 && lines.last.empty?
    lines
  end

  def walk_lcs(old_raw, new_raw)
    table = Array.new(old_raw.size + 1) { Array.new(new_raw.size + 1, 0) }
    old_raw.each_index.reverse_each do |i|
      new_raw.each_index.reverse_each do |j|
        table[i][j] = old_raw[i] == new_raw[j] ? table[i + 1][j + 1] + 1 : [ table[i + 1][j], table[i][j + 1] ].max
      end
    end

    result = []
    i = j = 0
    while i < old_raw.size && j < new_raw.size
      if old_raw[i] == new_raw[j]
        result << [ :same, i, j ]
        i += 1
        j += 1
      elsif table[i + 1][j] >= table[i][j + 1]
        result << [ :del, i, nil ]
        i += 1
      else
        result << [ :add, nil, j ]
        j += 1
      end
    end
    result.concat(old_raw[i..].each_index.map { |k| [ :del, i + k, nil ] })
    result.concat(new_raw[j..].each_index.map { |k| [ :add, nil, j + k ] })
  end
end
