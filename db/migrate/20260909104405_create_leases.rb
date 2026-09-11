class CreateLeases < ActiveRecord::Migration[8.1]
  def change
    create_table :leases do |t|
      t.references :job, null: false, foreign_key: true
      t.string :instance_id, null: false
      # The plaintext only ever reaches the worker
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :released_at
      t.string :release_reason

      t.timestamps
    end

    # One held lease per job
    add_index :leases, :job_id, unique: true, where: "released_at IS NULL",
      name: "index_leases_on_job_id_active"
    add_index :leases, [ :instance_id, :released_at ]
  end
end
