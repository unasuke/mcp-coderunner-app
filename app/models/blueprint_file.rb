class BlueprintFile < ApplicationRecord
  MAX_PATH_LENGTH = 255

  belongs_to :blueprint

  validates :path, presence: true, length: { maximum: MAX_PATH_LENGTH }, uniqueness: { scope: :blueprint_id }
  validate :path_stays_in_the_context

  private

  # Refused where the files are written rather than where they are unpacked (the
  # worker's own check stays). Whatever can be caught here is caught before a
  # human ever reviews and approves it
  def path_stays_in_the_context
    return if path.blank?

    errors.add(:path, "must be relative") if path.start_with?("/")
    errors.add(:path, "must not contain a backslash") if path.include?("\\")
    errors.add(:path, "must not escape the context") if path.split("/").include?("..")
  end
end
