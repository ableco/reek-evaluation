class PotentialLawyer < ApplicationRecord
  include SubscriptionHelpers
  include DatetimeScopes

  acts_as_paranoid

  # Gems
  mailkick_user

  # Enums
  enum source: {
    wta: "wta-org", ep: "ep", progressive: "progressive", legacy: "legacy"
  }

  # Associations
  belongs_to :lawyer, required: false
  belongs_to :referred_by, class_name: "User", required: false
  has_and_belongs_to_many :jurisdictions
  has_and_belongs_to_many :languages
  has_one :address,
          class_name: "LawyerAddress", as: :addressable, dependent: :destroy

  # Scopes
  scope :exclude_ep_partials,
        -> { where.not(source: "ep").or(where.not(lawyer_id: nil)) }
  datetime_range_scope :created_at
  scope :partial, -> { where(lawyer_id: nil) }
  scope :full_accounts, -> { where.not(lawyer_id: nil) }

  enum practicing_status: LawyerProfile::PRACTICING_STATUSES

  # Validations
  validates :email,
            format: {
              with: EmailAddressValidator::EMAIL_REGEX,
              message: :invalid_address
            }
  validates :email,
            email_address_uniqueness: true, if: :email_was_updated_in_admin?
  validates :mobile_phone, phone: true, allow_blank: true, unless: :progressive?
  validates_presence_of :address, if: :progressive?
  validates :practicing_status, presence: true, unless: :progressive?

  attribute :updated_from_admin, :boolean, default: false

  # Concerns
  include Searchable
  searchable_by :email
  searchable_by :first_name, { lawyer: %i[first_name] }, :search_by_first_name
  searchable_by :last_name, { lawyer: %i[last_name] }, :search_by_last_name

  # Other
  accepts_nested_attributes_for :address

  # Delegations
  delegate :zip_code, to: :address, allow_nil: true

  # Callbacks
  after_commit :subscribe_mailchimp_clone_list!

  def self.sources_for_select
    { :WTA => "wta", :EP => "ep", :Legacy => "legacy", "EC 2020" => "progressive" }
  end

  def self.find_or_initialize_by_email_case_insensitive(attrs)
    find_by_email_case_insensitive(attrs[:email]).take || new(attrs)
  end

  def self.find_by_email_case_insensitive(email)
    where("lower(email) = :email", email: email.downcase)
  end

  def self.associate_to_lawyer(lawyer, id: nil)
    potential_lawyer =
      if id
        find id
      else
        find_or_initialize_by_email_case_insensitive(email: lawyer.email)
      end

    potential_lawyer.lawyer = lawyer
    potential_lawyer.practicing_status = lawyer.practicing_status
    potential_lawyer.save!

    # Since this potential_lawyer has an associated lawyer it no longer
    # needs to have an address (lawyer_profile has one)
    potential_lawyer.address&.destroy
  end

  def lawyer_class
    case practicing_status
    when "Law Student or Recent Graduate"
      LawStudent
    else
      Attorney
    end
  end

  def lawyer_profile_class
    case practicing_status
    when "Law Student or Recent Graduate"
      LawStudentProfile
    else
      AttorneyProfile
    end
  end

  def law_student?
    practicing_status == "Law Student or Recent Graduate"
  end

  def has_lawyer_account?
    lawyer.present?
  end

  def to_s
    email
  end

  def email_was_updated_in_admin?
    updated_from_admin && email_changed?
  end

  def subscribe_mailchimp_clone_list!
    PotentialLawyers::UpdateOnMailchimpJob.perform_later(
      self.id,
      list_id: ENV["MAILCHIMP_LIST_ID_CLONE"]
    )
  end
end
