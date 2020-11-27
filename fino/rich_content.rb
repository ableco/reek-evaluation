class RichContent < ApplicationRecord
  belongs_to :record, polymorphic: true, touch: true

  has_many :rich_content_annotations, dependent: :destroy

  delegate :product_id, to: :record, allow_nil: true

  before_save :remove_stale_annotations

  def children
    root.fetch("children", [])
  end

  def children=(value)
    set_root(json_with_string_fallback(value))
  end

  def remove_annotation(id)
    replace_annotation(id, nil)
  end

  def replace_annotation(id, replacement)
    replaced =
      RichContentNode.replace_nodes(children, replacement) do |node|
        RichContentNode.annotation?(node, id)
      end
    set_root(replaced)
    save!
  end

  def mention_ids
    mention_nodes.pluck("id")
  end

  def mention_nodes
    RichContentNode.extract_nodes(children) { |node| RichContentNode.mention?(node) }
  end

  def annotation_nodes
    RichContentNode.extract_nodes(children) { |node| RichContentNode.annotation?(node) }
  end

  def active_annotation_ids
    annotation_nodes.pluck("id")
  end

  def stale_annotation_ids
    pending_rich_content_annotation_ids - active_annotation_ids
  end

  def pending_rich_content_annotation_ids
    rich_content_annotations.pending.pluck(:id)
  end

  def text
    RichContentNode.extract_text(children)
  end

  def html
    RichContentSerializer.serialize(children)
  end

  def pending_questions_count
    @pending_questions_count ||= rich_content_annotations.published.pending.question.count
  end

  def pending_suggestions_count
    @pending_suggestions_count ||= rich_content_annotations.published.pending.suggestion.count
  end

  def closed_annotations_count
    @closed_annotations_count ||= rich_content_annotations.published.dismissed.count +
                                  rich_content_annotations.published.accepted.count
  end

  private

  def json_with_string_fallback(value)
    ActiveSupport::JSON.decode(value)
  rescue JSON::ParserError
    [RichContentNode.text(value)]
  end

  def remove_stale_annotations
    rich_content_annotations.where(id: stale_annotation_ids).update_all(status: :dismissed)
  end

  def set_root(nodes)
    self.root = { RichContentNode::CHILDREN => RichContentNode.normalize(nodes) }
  end
end
