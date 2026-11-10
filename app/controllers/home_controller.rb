class HomeController < ApplicationController
  before_action :require_sign_in!

  def index
    @children = Bassinet::ChildRepo.new(household_id: current_household_id).all
    @selected_child = @children.first
    @today = Bassinet::Dynamo::Marshal.now_ms
  end
end
