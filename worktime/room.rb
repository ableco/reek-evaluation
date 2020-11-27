class Room < ApplicationRecord
  belongs_to :user, optional: true
  has_many :room_users
  has_many :messages, dependent: :destroy
  has_many :users, through: :room_users, dependent: :destroy
  has_one :canvas, dependent: :destroy

  validates :code, uniqueness: { case_sensitive: false }
  validates :name, presence: true
  before_create :set_code
  after_create :create_canvas

  def related_organization_domain
    user&.organization_domain || "gmail.com"
  end

  def current_participants
    User.where(room_identifier: participants_room_identifiers).select(:id, :room_identifier, :avatar_url, :name).map do |user|
      if participants_metadata.first.is_a?(Hash)
        if participant_metadata = participants_metadata.find { |participant| participant["id"] == user.room_identifier }
          user.audio = participant_metadata["audio"].to_s == "true"
        end
      end

      user.as_json(only: [:id, :room_identifier, :avatar_url, :name, :acronym_name])
    end
  end

  def participants_metadata
    metadata["participants"] || []
  end

  def participants_room_identifiers
    metadata["participants"].map do |participant|
      if participant.is_a?(String)
        participant
      else
        participant["id"]
      end
    end
  end

  def set_code
    self.code ||= Haikunator.haikunate
  end

  def create_canvas
    Canvas.find_or_create_by(room_id: id)
  end
end
