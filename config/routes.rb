# Plugin's routes
# See: http://guides.rubyonrails.org/routing.html

get 'milestone/index', to: 'milestone#index'

# predict view for issues (no project prefix)
get 'predict/issues/:issue_id', to: 'milestone#predict_issue'
post 'predict/issues/:issue_id/apply', to: 'milestone#apply_predict_issue'

# 프로젝트와 독립적인 issue_detail 라우트 추가
#get 'issue_detail/:id', to: 'milestone#issue_detail'

resources :projects do
  resources :milestone, :controller => 'milestone', :as => 'milestone' do
    collection do
      # version_id를 사용한 새로운 라우트 추가
      get 'gantt/versions/:version_id', to: 'milestone#gantt'
      get 'gantt/issues/:issue_id', to: 'milestone#gantt'
      get 'gantt', to: 'milestone#gantt'
      get 'schedule_summary', to: 'milestone#schedule_summary'
      #get 'validate', to: 'milestone#validate'
      #get 'sync_parent_date', to: 'milestone#sync_parent_date'
      post 'sync_parent_date', to: 'milestone#api_sync_parent_date'
      get 'group_detail', to: 'milestone#group_detail'
      get 'tetris/users/:user_id', to: 'milestone#tetris'
      get 'tetris/issues/:parent_issue_id', to: 'milestone#tetris'
      get 'tetris', to: 'milestone#tetris'
      get 'roadmap', to: 'milestone#roadmap'
      post 'save_roadmap_data', to: 'milestone#save_roadmap_data'
      get 'load_roadmap_data', to: 'milestone#load_roadmap_data'
      post 'create_roadmap', to: 'milestone#create_roadmap'
      post 'tetris/users/:user_id', to: 'milestone#tetris'
      post 'tetris/issues/:parent_issue_id', to: 'milestone#tetris'
      post 'tetris', to: 'milestone#tetris'
      get 'tools', to: 'milestone#tools'
      get 'tools/validate', to: 'milestone#tools', tool: 'validate'
      get 'tools/sync_parent_date', to: 'milestone#tools', tool: 'sync_parent_date'
      get 'tools/delayed_issues', to: 'milestone#tools', tool: 'delayed_issues'
      get 'tools/check_related_issues', to: 'milestone#tools', tool: 'check_related_issues'
      get 'report', to: 'milestone#report'
      get 'report/issues', to: 'milestone#report', report_type: 'issues'
      get 'report/bugs', to: 'milestone#report', report_type: 'bugs'
      # 기존 issue_detail 라우트는 제거됨
    end
  end
end
  
