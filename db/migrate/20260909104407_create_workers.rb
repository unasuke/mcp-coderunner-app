class CreateWorkers < ActiveRecord::Migration[8.1]
  def change
    create_table :workers do |t|
      t.string :worker_id, null: false
      # SHA256. The plaintext is shown once at issue and never stored
      t.string :token_digest, null: false
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :workers, :worker_id, unique: true
    add_index :workers, :token_digest, unique: true
  end
end
