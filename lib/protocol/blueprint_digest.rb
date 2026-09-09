# frozen_string_literal: true

require "digest"
require "json"

module Protocol
  # Blueprint の内容ハッシュ。承認はこの値に紐づくので、計算方法を一意に固定する。
  #
  # - キーの順序は下のリテラルの順（JSON.generate は挿入順で出す）
  # - files は path の昇順。入力の順番に依存させない
  # - content は改行も含めてそのまま。末尾改行の有無で digest は変わる
  # - name と summary は含めない。名前や説明を変えただけで再レビューにしない
  module BlueprintDigest
    # files: [{ path:, content:, executable: }] （文字列キーでも可）
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
