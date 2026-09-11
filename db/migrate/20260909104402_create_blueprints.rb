class CreateBlueprints < ActiveRecord::Migration[8.1]
  def change
    create_table :blueprints do |t|
      t.string :name, null: false
      # The one line a reviewer reads first. Not part of the digest
      t.string :summary, null: false
      t.text :dockerfile, null: false
      # SHA256 of the normalized content: 64 hex digits, with no sha256: prefix
      t.string :digest, null: false
      t.string :state, null: false, default: "pending_review"
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :oauth_application, foreign_key: { to_table: :oauth_applications }
      t.references :reviewed_by, foreign_key: { to_table: :users }
      t.datetime :reviewed_at
      t.text :review_note
      # The revision this came from, so review can read it as a diff
      t.references :parent, foreign_key: { to_table: :blueprints }

      t.timestamps
    end

    add_index :blueprints, :digest, unique: true
    # Naming a Blueprint resolves to the newest approved row under that name
    add_index :blueprints, [ :name, :state, :created_at ]
  end
end
