# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # 同じ内容がログと DB の 2 箇所に増えるのを避ける。中身は DB と /admin で見る
  :script, :dockerfile, :content, :stdout, :stderr,
  # 認可の途中で流れるもの
  :lease_token, :client_secret, :code, :code_verifier
]
