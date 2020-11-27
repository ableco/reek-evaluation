class College < ApplicationRecord
  has_one :college_admission
  has_one :college_financial
  has_one :college_mission
  has_many :college_programs
  has_many :college_costs
  has_many :college_demographics
  has_many :college_insights

  before_save :set_coordinates
  before_validation :generate_slug

  validates :slug, presence: true

  has_one_attached :logo

  enum level: [
    :"four-year",
    :"two-year",
    :"less-than-two-year"
  ], _prefix: true

  enum ownership: [
    :"public",
    :"private-nonprofit",
    :"private-for-profit"
  ], _prefix: true

  enum locale: [
    :"city-small",
    :"city-midsize",
    :"city-large",
    :"suburb-small",
    :"suburb-midsize",
    :"suburb-large",
    :"town-fringe",
    :"town-distant",
    :"town-remote",
    :"rural-fringe",
    :"rural-distant",
    :"rural-remote"
  ], _prefix: true

  delegate :acceptance_rate_overall,
           :sat_overall_average,
           :sat_math_25th,
           :sat_math_75th,
           :sat_critical_reading_25th,
           :sat_critical_reading_75th,
           :act_cumulative_25th,
           :act_cumulative_75th,
           :act_math_25th, :act_math_75th,
           :act_english_25th,
           :act_english_75th,
           :act_writing_25th,
           :act_writing_75th,
           to: :college_admission

  delegate :spend_per_student,
           :percentage_with_aid,
           :median_debt_overall,
           :earnings_after_10_years,
           :ipeds_spend_per_student,
           to: :college_financial

  scope :filtered_by_name, ->(input) {
    term = sanitize_sql_like(input)
    select_clause = sanitize_sql_array([
      "colleges.*,
      SIMILARITY(name, :term) as name_similarity,
      SIMILARITY(alias, :term) as alias_similarity,
      name ILIKE :including_term as includes_name,
      alias ILIKE :including_term as includes_alias",
      term: term,
      including_term: "%#{term}%"
    ])

    select(
      select_values + [select_clause]
    ).where(
      "SIMILARITY(name, :term) > :similarity_threshold OR
        SIMILARITY(alias, :term) > :similarity_threshold OR
        name ILIKE :including_term OR
        alias ILIKE :including_term",
      term: term,
      including_term: "%#{term}%",
      similarity_threshold: 0.2
    ).reorder(
      "includes_name DESC, name_similarity DESC, alias_similarity DESC, includes_alias DESC"
    )
  }

  scope :filtered_by_state, ->(states) {
    where(state_abbr: states)
  }

  scope :filtered_by_location, ->(longitude, latitude, distance_in_miles = 10) {
    # ST_Distance works in meters, we use this to convert miles to meters
    miles_to_meters = 1609.34
    long = ApplicationRecord.sanitize_sql_like(longitude)
    lat = ApplicationRecord.sanitize_sql_like(latitude)
    where("ST_Distance(coordinates, 'POINT(? ?)') < ?",
          lat.to_f, long.to_f, distance_in_miles.to_i * miles_to_meters)
  }

  scope :filtered_by_programs, ->(programs) {
    joins(:college_programs)
      .where("college_programs.percentage > 0")
      .where("college_programs.program" => programs)
  }

  scope :filtered_by_mission, ->(mission) {
    joins(:college_mission).where(mission, true)
  }

  scope :join_with_insights_for_user, ->(user) {
    sanitized_insights_join = sanitize_sql_array([
      "LEFT JOIN college_insights
        ON colleges.id = college_insights.college_id
        AND college_insights.user_id = ?",
      user.id
    ])

    sanitized_applications_join = sanitize_sql_array([
      "LEFT JOIN college_applications
        ON colleges.id = college_applications.college_id
        AND college_applications.user_id = ?",
      user.id
    ])

    select_clause = sanitize_sql_array([
      "colleges.*,
      college_insights.sat_percentiles_average as sat_percentiles_average,
      (college_applications.id is not null) as has_no_college_applications,
      college_insights.admission_category as admission_category,
      (colleges.id + ?) as college_random_value",
      user.sort_criteria_seed
    ])

    order_clause = [
      "has_no_college_applications",
      "college_insights.portfolio_admission DESC NULLS LAST",
      "college_insights.roi_quartile ASC NULLS LAST",
      "college_insights.sorting_distance ASC NULLS LAST",
      "college_random_value ASC NULLS LAST"
    ].join(", ")

    select(select_clause).joins(
      sanitized_insights_join
    ).joins(
      sanitized_applications_join
    ).order(order_clause)
  }

  # Needed for sorting and filtering by these fields on college resource
  attr_accessor :sat_percentiles_average, :distance, :admission_category

  def logo_url
    if self.logo.attached?
      resized_logo = logo.variant(resize_to_fill: [144, 144])
      if Rails.env.production?
        Rails.application.routes.url_helpers.rails_representation_path(resized_logo)
      else
        Rails.application.routes.url_helpers.url_for(resized_logo)
      end
    end
  end

  def cache_calculated_data
    update_columns(
      top_programs_names: calculate_top_programs_names,
      more_programs_count: calculate_more_programs_count,
      missions: calculate_missions
    )
  rescue ActiveModel::MissingAttributeError => error
    # CircleCI sometimes fails with this error even when this column is in the DB.
  end

  def to_s
    name
  end

  private

  def generate_slug
    return unless self.slug.blank?
    self.slug = ActiveSupport::Inflector.parameterize(self.name)
  end

  def set_coordinates
    self.coordinates = "POINT(#{longitude} #{latitude})"
  end

  def calculate_top_programs_names
    college_programs.order("percentage desc").limit(3).pluck(:program).map do |program|
      program.gsub("_", " ").titleize
    end
  end

  def calculate_more_programs_count
    total = college_programs.where.not(percentage: [nil, 0.0]).size
    total > 3 ? total - 3 : 0
  end

  def calculate_missions
    college_mission.attributes.to_a.select do |(key,value)|
      CollegeMission::MISSIONS.include?(key) && value
    end.map { |(key)| key.camelize(:lower) }
  end
end
