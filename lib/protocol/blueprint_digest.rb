# frozen_string_literal: true

require "digest"
require "json"

module Protocol
  # The content hash of a Blueprint. Approval is bound to this value, so how it
  # is computed is pinned down to exactly one answer.
  #
  # - Key order is the order of the literal below (JSON.generate emits insertion order)
  # - files are sorted by path ascending, so input order does not matter
  # - content is taken as-is, newlines included. A trailing newline changes the digest
  # - name and summary are left out. Renaming or rewording does not force another review
  module BlueprintDigest
    # files: [{ path:, content:, executable: }] (string keys are accepted too)
    def self.compute(dockerfile:, files:)
      payload = {
        "dockerfile" => dockerfile,
        "files" => normalize_files(files)
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def self.normalize_files(files)
      files.map { |file| normalize_file(file) }.sort_by { |file| file.fetch("path") }
    end

    def self.normalize_file(file)
      {
        "path" => fetch_any(file, :path),
        "content" => fetch_any(file, :content),
        "executable" => !!fetch_any(file, :executable, false)
      }
    end

    def self.fetch_any(file, key, *default)
      if file.key?(key)
        file.fetch(key)
      elsif file.key?(key.to_s)
        file.fetch(key.to_s)
      elsif default.empty?
        raise KeyError, "missing key: #{key}"
      else
        default.first
      end
    end
    private_class_method :normalize_file, :fetch_any
  end
end
