class CreateWorkerProcesses < ActiveRecord::Migration[8.1]
  def change
    create_table :worker_processes do |t|
      t.string :worker_id, null: false
      # A UUIDv7, generated on every start
      t.string :instance_id, null: false
      t.string :hostname
      t.integer :pid
      t.string :commit_hash, null: false
      t.integer :protocol_version, null: false
      t.string :ruby_version
      t.string :docker_version
      t.integer :capacity, null: false
      t.json :metadata
      t.datetime :started_at, null: false
      # Whether it is alive is decided by this age alone. The row existing proves nothing
      t.datetime :last_heartbeat_at, null: false
      t.datetime :stopped_at

      t.timestamps
    end

    add_index :worker_processes, :instance_id, unique: true
    add_index :worker_processes, [ :worker_id, :last_heartbeat_at ]
  end
end
