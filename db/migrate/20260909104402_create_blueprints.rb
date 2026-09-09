class CreateBlueprints < ActiveRecord::Migration[8.1]
  def change
    create_table :blueprints do |t|
      t.string :name, null: false
      # レビューする人間が最初に読む 1 行。digest には含めない
      t.string :summary, null: false
      t.text :dockerfile, null: false
      # 正規化した内容の SHA256。64 桁の hex で、sha256: の prefix は付けない
      t.string :digest, null: false
      t.string :state, null: false, default: "pending_review"
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :oauth_application, foreign_key: { to_table: :oauth_applications }
      t.references :reviewed_by, foreign_key: { to_table: :users }
      t.datetime :reviewed_at
      t.text :review_note
      # 改訂元。差分レビューのため
      t.references :parent, foreign_key: { to_table: :blueprints }

      t.timestamps
    end

    add_index :blueprints, :digest, unique: true
    # name 指定は「同名で最新の approved」を引く
    add_index :blueprints, [ :name, :state, :created_at ]
  end
end
