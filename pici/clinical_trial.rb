# frozen_string_literal: true

class ClinicalTrial < Project
  include PgSearch::Model
  include Maths

  enum trial_phase: %i[phase_1 phase_1b phase_2]
  enum trial_status: %i[pending_activation in_development enrolling_patients enrollment_complete study_closed]

  scope :by_status, ->(status) { where(trial_status: status) }
  scope :by_phase,  ->(phase) { where(trial_phase: phase) }
  scope :open, -> { where.not(trial_status: :study_closed) }

  after_create :create_email_subscription
  before_destroy :delete_email_subscription

  # Search
  pg_search_scope :search_by_name, against: %i[name identifier codename], using: { tsearch: { prefix: true } }

  # Validations
  validates :subtitle, presence: true
  validates :trial_status, presence: true

  def formatted_trial_phase
    phase_name = {
      phase_1: '1',
      phase_1b: '1B',
      phase_2: '2'
    }
    phase_name[trial_phase&.to_sym]
  end

  def status_color
    status_color = {
      pending_activation: '#EDB837',
      in_development: '#A7A8AA',
      enrolling_patients: '#33C546',
      enrollment_complete: '#5354D0'
    }
    status_color[trial_status&.to_sym]
  end

  def status_pill_color
    status_pill_color = {
      pending_activation: '#FBF1D7',
      in_development: '#EDEEEE',
      enrolling_patients: '#D6F3DA',
      enrollment_complete: '#DDDDF6'
    }
    status_pill_color[trial_status&.to_sym]
  end

  def email_opt_name
    identifier_upcase = identifier.upcase
    return identifier_upcase unless codename.present?

    "#{identifier_upcase}: #{codename.upcase}"
  end

  def formatted_trial_status
    trial_status.humanize.titleize
  end

  def formatted_codename
    codename.upcase if codename.present?
  end

  def formatted_identifier
    identifier.upcase if identifier.present?
  end

  def formatted_code
    formatted_codename || formatted_identifier
  end

  def current_periodic_update(date = Date.today)
    return nil if periodic_updates.size.zero?

    last_periodic_update = periodic_updates.ordered_by_period_date.last
    if last_periodic_update.period_date == Dates.periodic_month(date)
      last_periodic_update
    end
  end

  def active_periodic_update
    periodic_updates.active_ones
  end

  def stored_periodic_update
    periodic_updates.stored_ones
  end

  def stats_periodic_update
    nil || active_periodic_update.last || stored_periodic_update.last
  end

  def enrolled_data
    EnrolledStruct.new(stats_periodic_update)
  end

  def cohort_data
    CohortsStruct.new(stats_periodic_update)
  end

  def clinical_site_data
    SitesStruct.new(stats_periodic_update)
  end

  def patient_enrollment
    if stats_periodic_update.present?
      Maths.sum_array(stats_periodic_update.clinical_cohorts.map(&:current_enrollment))
    end
  end

  def patient_enrollment_target
    if stats_periodic_update.present?
      size = stats_periodic_update.sites_min_size
      Maths.sum_array(stats_periodic_update.clinical_cohorts.map(&:target_enrollment)) / size
    end
  end

  def delete_email_subscription
     EmailSubscription.delete_subscription(subject_id: id, subject_type: PeriodicUpdate.name)
  end

  def create_email_subscription
    if trial_status != 'study_closed'
      ClinicalTrial.transaction do
        User.all.each do |user|
          EmailSubscription.find_or_create_by(
            subject: self,
            user: user,
            subject_type: PeriodicUpdate.name,
            active: false
          )
        end
      end
    end
  end

  def sorted_centers
    clinical_sites.map(&:center).compact.uniq.sort_by(&:shorthand)
  end

  def sorted_institutions
    clinical_sites.map(&:institution).compact.uniq.sort_by(&:shorthand)
  end

  class << self
    def count_by_status
      status = ClinicalTrial.group(:trial_status).count
      StatusStruct.new(
        status['pending_activation'] || 0,
        status['in_development'] || 0,
        status['enrolling_patients'] || 0,
        status['enrollment_complete'] || 0,
        status['study_closed'] || 0
      )
    end

    def count_by_enrollment
      all_clinical_trials = ClinicalTrial.all
      all_time_enrollment = [
        Maths.sum_array(all_clinical_trials.map(&:patient_enrollment)),
        Maths.sum_array(all_clinical_trials.map(&:patient_enrollment_target))
      ]
      patients = ClinicalTrial.enrolling_patients
      active_enrollment = [
        Maths.sum_array(patients.map(&:patient_enrollment)),
        Maths.sum_array(patients.map(&:patient_enrollment_target))
      ]
      EnrollmentStruct.new(all_time_enrollment.first || 0, all_time_enrollment.second || 0, active_enrollment.first || 0, active_enrollment.second || 0)
    end

    def enrollment_by_center
      sub_query = ClinicalTrial
                  .joins(:clinical_sites)
                  .select('clinical_sites.center_id, clinical_sites.enrollment')
                  .where('clinical_sites.center_id IS NOT NULL')
                  .to_sql

      query = Center
              .joins("LEFT JOIN (#{sub_query}) AS q ON q.center_id = centers.id")
              .group('centers.id')
              .pluck(Arel.sql('centers.shorthand, SUM(q.enrollment), COUNT(*)'))

      query.map { |shorthand, enrolled, trials| OrganizationStruct.new(shorthand, enrolled || 0, enrolled ? trials || 0 : 0) }
    end

    def enrollment_by_institution
      sub_query = ClinicalTrial
                  .joins(:clinical_sites)
                  .select('clinical_sites.institution_id, clinical_sites.enrollment')
                  .where('clinical_sites.institution_id IS NOT NULL')
                  .to_sql

      query = Institution
              .joins("LEFT JOIN (#{sub_query}) AS q ON q.institution_id = institutions.id")
              .group('institutions.id')
              .pluck(Arel.sql('institutions.name, SUM(q.enrollment), COUNT(*)'))

      query.map { |shorthand, enrolled, trials| OrganizationStruct.new(shorthand, enrolled || 0, enrolled ? trials || 0 : 0) }
    end

    def enrollment_all_institutions(all_institutions)
      if all_institutions.present?
        OrganizationStruct.new(nil, all_institutions.sum(&:enrolled), all_institutions.sum(&:trials))
      end
    end
  end

  StatusStruct = Struct.new(:pending_activation, :in_development, :enrolling_patients, :enrollment_complete, :study_closed)
  OrganizationStruct = Struct.new(:organization, :enrolled, :trials)
  EnrollmentStruct = Struct.new(:all_time_enrolled, :all_time_target, :active_enrolled, :active_target)
end
