class UserProgress < ApplicationRecord
  # Associations
  belongs_to :user
  belongs_to :check_in, optional: true

  # Scopes
  scope :by_week, ->(start_date) { where(created_date: start_date.all_week) }
  scope :by_month, ->(start_date) { where(created_date: start_date.all_month) }

  def self.refresh_row(user_id, date)
    arel_count = Arel.sql("count(*)")
    check_in_id =
      CheckIn
        .where(user_id: user_id)
        .where(["date(created_at) = ?", date])
      .pluck(:id).first
    kindness_sent =
      KindnessAct
        .where(from_id: user_id)
        .where(["date(created_at) = ?", date])
        .group("date(created_at)")
        .pluck(arel_count).first || 0
    thanks_sent =
      ThanksAct
        .joins(:kindness_act)
        .where(kindness_acts: { to_id: user_id })
        .where(["date(thanks_acts.created_at) = ?", date])
        .group("date(thanks_acts.created_at)")
        .pluck(arel_count).first || 0
    return false if check_in_id == nil && kindness_sent == 0 && thanks_sent == 0
    sql = sanitize_sql_array([<<~SQL, user_id, date, check_in_id, kindness_sent, thanks_sent])
      INSERT INTO user_progresses (user_id, created_date, check_in_id, kindness_sent_count, thanks_sent_count)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT (user_id, created_date)
      DO UPDATE SET check_in_id = EXCLUDED.check_in_id,
                    kindness_sent_count = EXCLUDED.kindness_sent_count,
                    thanks_sent_count = EXCLUDED.thanks_sent_count;
    SQL
    connection.execute sql
  end
end

# == Schema Information
#
# Table name: user_progresses
#
#  id                  :bigint(8)        not null, primary key
#  created_date        :date             not null
#  kindness_sent_count :integer
#  thanks_sent_count   :integer
#  check_in_id         :bigint(8)
#  user_id             :bigint(8)        not null
#
# Indexes
#
#  index_user_progresses_on_check_in_id               (check_in_id)
#  index_user_progresses_on_user_id                   (user_id)
#  index_user_progresses_on_user_id_and_created_date  (user_id,created_date) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (check_in_id => check_ins.id)
#  fk_rails_...  (user_id => users.id)
#
