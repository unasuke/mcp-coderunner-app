class CreateWorkerProcesses < ActiveRecord::Migration[8.1]
  def change
    create_table :worker_processes do |t|
      t.string :worker_id, null: false
      # 起動のたびに生成する UUIDv7
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
      # 生死の判定はこの古さだけで行う。行の存在を生存の証拠にしない
      t.datetime :last_heartbeat_at, null: false
      t.datetime :stopped_at

      t.timestamps
    end

    add_index :worker_processes, :instance_id, unique: true
    add_index :worker_processes, [ :worker_id, :last_heartbeat_at ]
  end
end
