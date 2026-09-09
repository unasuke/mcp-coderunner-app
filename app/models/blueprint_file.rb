class BlueprintFile < ApplicationRecord
  MAX_PATH_LENGTH = 255

  belongs_to :blueprint

  validates :path, presence: true, length: { maximum: MAX_PATH_LENGTH }, uniqueness: { scope: :blueprint_id }
  validate :path_stays_in_the_context

  private

  # 展開する側ではなく、書き出す側でも弾く（ワーカー側の検証は残す）。
  # ここで弾けるものは、人間がレビューして承認する前に落としておく
  def path_stays_in_the_context
    return if path.blank?

    errors.add(:path, "must be relative") if path.start_with?("/")
    errors.add(:path, "must not contain a backslash") if path.include?("\\")
    errors.add(:path, "must not escape the context") if path.split("/").include?("..")
  end
end
