# frozen_string_literal: true

class InvestmentValuation < ActiveRecord::Base
  has_paper_trail

  include HasInvestmentDateValidations

  belongs_to :investment
  belongs_to :creator, class_name: 'User'
  belongs_to :task, optional: true

  validates :amount, presence: true, not_big_number: true
  validates :unit_count, presence: true, if: :should_validate_unit_count_presence?
  validates :unit_count, not_big_number: true
  validates :creator_id, presence: true

  attr_accessor :given_price_per_unit, :requires_given_price_per_unit

  with_options if: -> { requires_given_price_per_unit && investment&.quantity? } do |assoc|
    assoc.before_validation :fill_amount_from_given_price_per_unit
    assoc.validates :given_price_per_unit, presence: true
    assoc.validates :given_price_per_unit, numericality: { greater_than_or_equal_to: 0 }
    assoc.validates :given_price_per_unit, not_big_number: true
  end

  validate :date_not_in_the_future

  before_save :save_original_price_per_unit
  before_validation :ensure_creator
  after_save :update_investment_valuation_amount
  after_commit :update_previous_investment_valuation_amount
  after_destroy_commit :update_investment_valuation_amount

  scope :ordered_by_date, -> { order(Arel.sql('date::date asc,created_at asc')) }
  scope :ongoing, -> { where(historical: false) }

  def holds_quantity?
    unit_count.present?
  end

  def price_per_unit
    return 0 if (unit_count || 0).zero?

    amount / unit_count
  end

  private

  def should_validate_unit_count_presence?
    investment&.quantity.present?
  end

  def ensure_creator
    return if creator_id.present?

    self.creator_id = investment.creator_id
  end

  def save_original_price_per_unit
    if original_price_per_unit.blank? || original_price_per_unit.zero?
      self.original_price_per_unit = price_per_unit
    end
  end

  def update_investment_valuation_amount
    investment&.update_valuation_associations!
  end

  def fill_amount_from_given_price_per_unit
    if given_price_per_unit.present?
      self.amount = given_price_per_unit * unit_count
    end
  end

  class NullInvestment
    def update_ongoing_valuations
      #---
    end
  end

  def update_previous_investment_valuation_amount
    date_and_amount_saved = saved_change_to_attribute?(:date) && saved_change_to_attribute?(:amount)
    return unless date_and_amount_saved

    (investment || NullInvestment.new).update_ongoing_valuations
  end
end
