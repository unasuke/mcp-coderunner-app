class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :github_uid, null: false
      t.string :login, null: false
      t.string :name
      t.string :avatar_url
      # 既定値は pending。役割の設定を書き忘れたユーザーは何もできない
      t.string :role, null: false, default: "pending"
      t.datetime :approved_at
      t.references :approved_by, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :users, :github_uid, unique: true
  end
end
