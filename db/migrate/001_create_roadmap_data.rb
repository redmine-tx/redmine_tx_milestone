class CreateRoadmapData < ActiveRecord::Migration[6.1]
  def up
    create_table :roadmap_data, options: 'ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci' do |t|
      t.integer :project_id, null: false
      t.string :name, null: false, default: 'Default Roadmap', charset: 'utf8mb4', collation: 'utf8mb4_unicode_ci'
      t.text :description, charset: 'utf8mb4', collation: 'utf8mb4_unicode_ci'
      t.text :data, null: false, charset: 'utf8mb4', collation: 'utf8mb4_unicode_ci' # JSON 데이터를 text로 저장
      t.boolean :is_active, default: true
      t.timestamps
    end
    
    add_foreign_key :roadmap_data, :projects
    add_index :roadmap_data, [:project_id, :updated_at]
    add_index :roadmap_data, [:project_id, :is_active]
  end
  
  def down
    # 외래 키 제약 조건을 먼저 삭제
    remove_foreign_key :roadmap_data, :projects if foreign_key_exists?(:roadmap_data, :projects)
    
    # 인덱스 삭제
    remove_index :roadmap_data, [:project_id, :is_active] if index_exists?(:roadmap_data, [:project_id, :is_active])
    remove_index :roadmap_data, [:project_id, :updated_at] if index_exists?(:roadmap_data, [:project_id, :updated_at])
    
    # 테이블 삭제
    drop_table :roadmap_data
  end
end 