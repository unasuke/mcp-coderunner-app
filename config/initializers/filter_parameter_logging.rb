# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # Keeps the same content from accumulating in both the log and the database.
  # To read it, look at the database or /admin
  :script, :dockerfile, :content, :stdout, :stderr,
  # What moves across the wire during authorization
  :lease_token, :client_secret, :code, :code_verifier
]
