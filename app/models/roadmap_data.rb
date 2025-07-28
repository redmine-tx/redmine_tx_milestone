class RoadmapData < ApplicationRecord
  belongs_to :project
  
  validates :project_id, presence: true
  validates :data, presence: true
  
  # JSON 데이터를 파싱하여 반환
  def parsed_data
    @parsed_data ||= JSON.parse(data)
  rescue JSON::ParserError
    {}
  end
  
  # JSON 데이터 접근을 위한 메서드
  def categories
    parsed_data['categories'] || []
  end
  
  def metadata
    parsed_data['metadata'] || {}
  end
  
  # JSON 데이터 설정
  def set_data(hash_data)
    self.data = hash_data.to_json
  end
  
  # 프로젝트별 활성 로드맵 가져오기
  def self.active_for_project(project_id)
    where(project_id: project_id, is_active: true).order(updated_at: :desc).first
  end
end 