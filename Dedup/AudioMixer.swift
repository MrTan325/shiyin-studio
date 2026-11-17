import Foundation
import AVFoundation

/// All tracks use one future device-clock start; weights sum to one to avoid clipping.
final class AudioMixer:ObservableObject {
    @Published var songs=[SongPrint]()
    @Published var isPlaying=false
    @Published var gains=[Float]()
    @Published var blend:Double=0
    @Published var timeline:Double=0
    @Published var message=""
    @Published var aligned=true
    private var players=[AVAudioPlayer]()
    private var offsets=[Double]()
    private var timer:Timer?
    var activePlayerCount:Int {players.filter{$0.isPlaying}.count}
    var playbackTimes:[Double] {players.map{$0.currentTime}}
    var outputVolumes:[Float] {players.map{$0.volume}}
    var duration:Double { zip(songs,offsets).map{max(0,$0.duration-$1)}.min() ?? 0 }
    func replace(_ tracks:[SongPrint],matches:[Match]) {stop();songs=[];for t in tracks {add(t,matches:matches)} }
    func add(_ song:SongPrint,matches:[Match]) {
        guard !songs.contains(where:{$0.path==song.path}) else {return}
        guard songs.count<3 else {message="最多同时比较 3 首，请先移除一首。";return}
        pause();players=[];songs.append(song);rebuildOffsets(matches);crossfade(0)
    }
    func remove(_ path:String,matches:[Match]) {
        stop();songs.removeAll{$0.path==path};players=[];rebuildOffsets(matches);crossfade(0)
    }
    private func rebuildOffsets(_ matches:[Match]) {
        guard let anchor=songs.first else {offsets=[];return}
        var positions=[anchor.path:0.0]
        // Solve time offsets along candidate edges; never sum ambiguous cycles repeatedly.
        for _ in 0..<3 {
            for m in matches {
                if let a=positions[m.first.path], positions[m.second.path]==nil {positions[m.second.path]=a+Double(m.offset)}
                else if let b=positions[m.second.path],positions[m.first.path]==nil {positions[m.first.path]=b-Double(m.offset)}
            }
        }
        let relative=songs.map {positions[$0.path] ?? 0}
        let minimum=relative.min() ?? 0
        offsets=relative.map {aligned ? $0-minimum:0}
        timeline=0
        if songs.contains(where:{positions[$0.path]==nil}) {message="部分歌曲没有匹配偏移，使用文件起点对齐；可关闭自动对齐。"}
        else {message=""}
    }
    func changeAlignment(_ matches:[Match]) {stop();players=[];rebuildOffsets(matches)}
    func crossfade(_ value:Double) {
        blend=max(0,min(Double(max(0,songs.count-1)),value))
        gains=(0..<songs.count).map {Float(max(0,1-abs(Double($0)-blend)))}
        applyVolumes()
    }
    func setGain(_ i:Int,_ value:Float) {
        guard gains.indices.contains(i) else {return}
        gains[i]=max(0,min(1,value));applyVolumes()
    }
    private func applyVolumes() {
        let sum=max(1,gains.reduce(0,+))
        for (i,p) in players.enumerated() {p.volume=gains.indices.contains(i) ? gains[i]/sum:0}
    }
    func play() {
        guard songs.count>=2 else {message="请添加 2 或 3 首歌曲。";return}
        do {
            if players.count != songs.count {
                players=try songs.map {song in
                    let p=try AVAudioPlayer(contentsOf:URL(fileURLWithPath:song.path))
                    guard p.prepareToPlay() else {throw AudioError.message("无法准备播放：\(song.name)")};return p
                }
            }
            if timeline>=duration {timeline=0}
            for (i,p) in players.enumerated() {p.currentTime=min(p.duration,timeline+offsets[i])}
            applyVolumes()
            let start=(players.first?.deviceCurrentTime ?? 0)+0.15
            for p in players {guard p.play(atTime:start) else {throw AudioError.message("同步播放启动失败")}}
            isPlaying=true;message=""
            timer?.invalidate();timer=Timer.scheduledTimer(withTimeInterval:0.15,repeats:true) {[weak self] _ in
                guard let self=self,let p=self.players.first else {return}
                if p.deviceCurrentTime < start+0.02 {return}
                self.timeline=max(0,p.currentTime-(self.offsets.first ?? 0))
                if self.timeline>=self.duration-0.1 || !self.players.contains(where:{$0.isPlaying}) {self.pause()}
            }
        } catch {pause();players=[];message="无法试听：\(error.localizedDescription)"}
    }
    func pause() {timer?.invalidate();timer=nil;players.forEach{$0.pause()};isPlaying=false}
    func stop() {pause();players.forEach{$0.stop()};timeline=0}
    func seek(_ value:Double) {
        let resume=isPlaying;pause();timeline=max(0,min(duration,value))
        for (i,p) in players.enumerated() {p.currentTime=timeline+offsets[i]}
        if resume {play()}
    }
    deinit {timer?.invalidate()}
}
