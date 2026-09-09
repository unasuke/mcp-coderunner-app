# frozen_string_literal: true

require_relative "helper"

class BlueprintDigestTest < Minitest::Test
  def compute(dockerfile:, files:)
    Protocol::BlueprintDigest.compute(dockerfile:, files:)
  end

  def test_files_are_sorted_by_path
    a = compute(dockerfile: "FROM ruby", files: [ { path: "a", content: "1" }, { path: "b", content: "2" } ])
    b = compute(dockerfile: "FROM ruby", files: [ { path: "b", content: "2" }, { path: "a", content: "1" } ])

    assert_equal a, b
  end

  def test_executable_defaults_to_false_and_changes_the_digest
    without = compute(dockerfile: "FROM ruby", files: [ { path: "run", content: "x" } ])
    explicit = compute(dockerfile: "FROM ruby", files: [ { path: "run", content: "x", executable: false } ])
    executable = compute(dockerfile: "FROM ruby", files: [ { path: "run", content: "x", executable: true } ])

    assert_equal without, explicit
    refute_equal without, executable
  end

  def test_string_and_symbol_keys_agree
    symbols = compute(dockerfile: "FROM ruby", files: [ { path: "a", content: "1" } ])
    strings = compute(dockerfile: "FROM ruby", files: [ { "path" => "a", "content" => "1" } ])

    assert_equal symbols, strings
  end

  def test_trailing_newline_changes_the_digest
    refute_equal compute(dockerfile: "FROM ruby", files: []), compute(dockerfile: "FROM ruby\n", files: [])
  end

  def test_digest_is_bare_hex
    digest = compute(dockerfile: "FROM ruby", files: [])

    assert_match(/\A[0-9a-f]{64}\z/, digest)
  end
end
