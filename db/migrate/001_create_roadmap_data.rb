class CreateRoadmapData < ActiveRecord::Migration[6.1]
  def up
    unless table_exists?(:roadmap_data)
      create_table :roadmap_data, options: 'ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci' do |t|
        t.integer :project_id, null: false
        t.string :name, null: false, default: 'Default Roadmap', charset: 'utf8mb4', collation: 'utf8mb4_unicode_ci'
        t.text :description, charset: 'utf8mb4', collation: 'utf8mb4_unicode_ci'
        t.text :data, null: false, charset: 'utf8mb4', collation: 'utf8mb4_unicode_ci' # JSON 데이터를 text로 저장
        t.boolean :is_active, default: true
        t.timestamps
      end

      add_foreign_key :roadmap_data, :projects unless foreign_key_exists?(:roadmap_data, :projects)
      add_index :roadmap_data, [:project_id, :updated_at] unless index_exists?(:roadmap_data, [:project_id, :updated_at])
      add_index :roadmap_data, [:project_id, :is_active] unless index_exists?(:roadmap_data, [:project_id, :is_active])
    end
  end

  def down
    if table_exists?(:roadmap_data)
      remove_foreign_key :roadmap_data, :projects if foreign_key_exists?(:roadmap_data, :projects)
      remove_index :roadmap_data, [:project_id, :is_active] if index_exists?(:roadmap_data, [:project_id, :is_active])
      remove_index :roadmap_data, [:project_id, :updated_at] if index_exists?(:roadmap_data, [:project_id, :updated_at])
      drop_table :roadmap_data
    end
  end
end
