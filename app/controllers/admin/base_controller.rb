module Admin
  # /admin は admin ロールのみ。見た目は作り込まない（判断に必要なのは中身と差分）。
  class BaseController < ApplicationController
    before_action :require_admin!
  end
end
