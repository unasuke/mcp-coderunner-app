class CreateBlueprintFiles < ActiveRecord::Migration[8.1]
  def change
    create_table :blueprint_files do |t|
      t.references :blueprint, null: false, foreign_key: true
      t.string :path, null: false
      t.text :content, null: false
      # No mode column. The only distinction worth having is whether a file is
      # executable, and an arbitrary mode would let setuid / setgid through
      t.boolean :executable, null: false, default: false

      t.timestamps
    end

    add_index :blueprint_files, [ :blueprint_id, :path ], unique: true
  end
end
