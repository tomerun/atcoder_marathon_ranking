require "ecr/macros"
require "http/client"
require "json"
require "yaml"

class Contest
  property :short_name, :ids, :mul

  def initialize(@short_name : String, @ids : Array(String), @mul : Bool)
  end
end

class Person
  property :name, :sum, :win, :top5, :top10, :count, :points, :ranks, :total_rank

  def initialize(@name : String)
    @sum = 0
    @win = 0
    @top5 = 0
    @top10 = 0
    @count = 0
    @points = Array(Int32 | Nil).new(CONTESTS.size, nil)
    @ranks = Array(Int32 | Nil).new(CONTESTS.size, nil) # 0 origin
    @total_rank = -1
  end

  def to_s(io)
    io << sprintf("%20s %3d %2d %2d %2d %2d", @name, @sum, @win, @top5, @top10, @count)
  end

  def css_color
    if @sum >= 500 && @top5 >= 3
      return "#ff0000" # red
    elsif @sum >= 300 && @top5 >= 1
      return "#ff8000" # orange
    elsif @sum >= 150 && @top10 >= 1
      return "#c0c000" # yellow
    elsif @sum >= 75
      return "#0000ff" # blue
    elsif @sum >= 40
      return "#00c0c0" # cyan
    elsif @sum >= 20
      return "#008000" # green
    elsif @sum >= 1
      return "#804000" # brown
    elsif @count >= 1
      return "#808080" # gray
    else
      return "#000000" # black
    end
  end

  def min_rank
    return @ranks.compact.min
  end
end

GP30 = [100, 75, 60, 50, 45, 40, 36, 32, 29, 26, 24, 22, 20, 18, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1]

CONTESTS = [] of Contest

DATA_PATH = "data/"

def calc_scores_mul(contest) : Array(Tuple(Int64, Int64, String))
  # collect scores
  contestants = Array(Tuple(String, Array(Int64))).new # contestant_name, scores
  tasks = Array(String).new
  contest.ids.each do |contest_id|
    json = JSON.parse(File.read(contest_data_path(contest_id)))
    cur_tasks = json["TaskInfo"].as_a.map { |t| t.as_h["TaskScreenName"].as_s }
    if tasks.empty?
      tasks = cur_tasks
    else
      if tasks != cur_tasks
        raise Exception.new("Taskがコンテスト間で違っている")
      end
    end
    json["StandingsData"].as_a.map(&.as_h).each do |p|
      name = p["UserScreenName"].as_s
      scores = tasks.map do |task_name|
        task_result = p["TaskResults"].as_h
        task_result.has_key?(task_name) ? task_result[task_name].as_h["Additional"].as_a[0].as_i64 : -1i64
      end
      contestants << {name, scores}
    end
  end
  contestants = contestants.reject { |c| c[1].all?(-1) } # remove who submitted nothing

  # convert to rank
  tasks.size.times do |i|
    contestants.sort_by! { |c| -c[1][i] }
    prev = contestants[0][1][i]
    contestants[0][1][i] = 1
    1.upto(contestants.size - 1) do |j|
      if contestants[j][1][i] == prev || contestants[j][1][i] == -1 && prev == 0
        contestants[j][1][i] = contestants[j - 1][1][i]
      else
        prev = contestants[j][1][i]
        contestants[j][1][i] = j.to_i64 + 1
      end
    end
  end
  return contestants.map { |c| {c[1].product, 0i64, c[0]} }
end

def calc_scores_normal(contest) : Array(Tuple(Int64, Int64, String))
  ps = [] of {Int64, Int64, String}
  contest.ids.each do |contest_id|
    json = JSON.parse(File.read(contest_data_path(contest_id)))
    json["StandingsData"].as_a.each do |p|
      next if p["TotalResult"]["Score"].as_i64 == 0 # 正のスコアを得ているかの判定
      name = p["UserScreenName"].as_s
      score = p["TotalResult"]["Score"].as_i64
      time = p["TotalResult"]["Elapsed"].as_i64
      if score > 0 && ps.all? { |p| p[0] != name }
        ps << {-score, time, name}
      end
    end
  end
  return ps
end

def contest_data_path(contest_id)
  return "#{DATA_PATH}#{contest_id}.json"
end

def process_contest(contest, contest_index, persons)
  # download
  contest.ids.each do |contest_id|
    filename = contest_data_path(contest_id)
    if !File.exists?(filename)
      puts "download #{contest_id}..."
      if contest.mul
        response = HTTP::Client.get("https://atcoder.jp/contests/#{contest_id}/standings/multiply_ranks/json")
      else
        response = HTTP::Client.get("https://atcoder.jp/contests/#{contest_id}/standings/json")
      end
      File.write(filename, response.body)
      sleep(2)
    end
  end

  if contest.mul
    ps = calc_scores_mul(contest)
  else
    ps = calc_scores_normal(contest)
  end
  prev_rank = 0
  ps.sort!
  ps.each_with_index do |p, i|
    rank = i > 0 && ps[i - 1][0] == p[0] && ps[i - 1][1] == p[1] ? prev_rank : i
    if !persons.has_key?(p[2])
      person = Person.new(p[2])
      persons[p[2]] = person
    else
      person = persons[p[2]]
    end
    if rank < GP30.size
      person.sum += GP30[rank]
      person.points[contest_index] = GP30[rank]
    else
      person.points[contest_index] = 0
    end
    person.win += 1 if rank == 0
    person.top5 += 1 if rank < 5
    person.top10 += 1 if rank < 10
    person.count += 1
    person.ranks[contest_index] = rank
    prev_rank = rank
  end
end

def load_config
  config_path = ARGV.empty? ? "config.yml" : ARGV[0]
  config_data = YAML.parse(File.read(config_path))
  config_data["contests"].as_h.each do |contest_name, contest_value|
    v = contest_value.as_h
    ids = v["contest_ids"].as_a.map(&.as_s)
    mult = v["mult"].as_bool
    CONTESTS << Contest.new(contest_name.as_s, ids, mult)
  end
  CONTESTS.reverse!
end

def main
  Dir.mkdir(DATA_PATH) if !Dir.exists?(DATA_PATH)
  load_config()
  persons_hash = {} of String => Person
  CONTESTS.each_with_index do |contest, i|
    process_contest(contest, i, persons_hash)
  end
  persons = persons_hash.values.sort_by { |p| {-p.sum, p.min_rank, -p.win, -p.top5, -p.top10, -p.count, p.name} }
  persons.each_with_index do |p, i|
    if i > 0 && persons[i - 1].sum == p.sum
      p.total_rank = persons[i - 1].total_rank
    else
      p.total_rank = i + 1
    end
  end
  puts ECR.render("template/ranking.ecr")
end

main
