# frozen_string_literal: true

ReActionView.configure do |config|
  # Every template here is .html.erb, so interception is what puts them through
  # Herb::Engine at all. Without it only .html.herb would go through it, and this
  # gem would be doing nothing.
  config.intercept_erb = true

  # Enable debug mode in development (adds debug attributes to HTML)
  config.debug_mode = Rails.env.development?

  # Path used for editor "open in editor" links (optional, defaults to Rails.root)
  # config.project_path = ENV.fetch('PROJECT_PATH', Rails.root.to_s)

  # Validation mode (:raise, :overlay, or :none) — defaults to :raise in test, :overlay otherwise
  # config.validation_mode = :overlay

  # How to handle templates that come from gems (:fallback, :skip, or :compile), defaults to :fallback
  # config.external_template_mode = :skip

  # Add custom transform visitors to process templates before compilation
  # config.transform_visitors = [
  #   Herb::Visitor::new
  # ]
end
