# frozen_string_literal: true

class EntryPresenter
  def initialize(entry)
    @entry = entry
  end

  def as_json(*)
    EntrySummaryPresenter.new(@entry).as_json.merge(
      summary: @entry.summary,
      content: @entry.content
    )
  end
end
