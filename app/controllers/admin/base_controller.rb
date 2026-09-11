module Admin
  # /admin is for the admin role alone.
  class BaseController < ApplicationController
    before_action :require_admin!
  end
end
