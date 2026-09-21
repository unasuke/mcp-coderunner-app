class AddRetriedFromToJobs < ActiveRecord::Migration[8.1]
  def change
    # Which job this one was re-run from. A re-run is a new row -- a job holds one
    # result and the leases it took, and resetting those would erase what actually
    # happened -- so this is the only thing that makes the pair read as a pair
    add_reference :jobs, :retried_from, foreign_key: { to_table: :jobs }
  end
end
