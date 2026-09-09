class CreateSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :sessions do |t|
      t.references :user, null: false, foreign_key: true
      # cookie に入るのは平文だが、DB に置くのは SHA256 だけ
      t.string :token_digest, null: false
      t.string :user_agent
      t.string :ip_address
      t.datetime :last_used_at, null: false

      t.timestamps
    end

    add_index :sessions, :token_digest, unique: true
  end
end
