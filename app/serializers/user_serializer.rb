class UserSerializer
  include Alba::Resource

  attributes :id, :email, :created_at
end
