class CreateBlueprintFiles < ActiveRecord::Migration[8.1]
  def change
    create_table :blueprint_files do |t|
      t.references :blueprint, null: false, foreign_key: true
      t.string :path, null: false
      t.text :content, null: false
      # mode は持たない。必要な区別は実行可能かどうかだけで、
      # 任意の mode を許すと setuid / setgid も通る
      t.boolean :executable, null: false, default: false

      t.timestamps
    end

    add_index :blueprint_files, [ :blueprint_id, :path ], unique: true
  end
end
