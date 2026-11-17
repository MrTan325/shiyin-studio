import SwiftUI
import AppKit

struct BatchSelectionView:View {
    @ObservedObject var model:Model
    @Environment(\.dismiss) private var dismiss
    @State var criterion:BatchCriterion = .folder
    @State var order:BatchOrder = .smaller
    @State var folder=""
    @State var minimum=""
    @State var maximum=""
    @State var similarity:Double=0.94
    @State var feedback=""
    @State var action:BatchAction = .select
    @State var keywords=""
    @State var requireAllKeywords=false
    var body:some View {
        ScrollView {
        VStack(alignment:.leading,spacing:18) {
            Text("批量勾选待移除文件").font(.title2.bold())
            Text("仅作用于当前阈值下的候选。这里只勾选，不会移动文件；每对候选至少保留一份。").font(.callout).foregroundStyle(.secondary)
            Picker("依据",selection:$criterion) {ForEach(BatchCriterion.allCases,id:\.self) {Text($0.rawValue).tag($0)}}.pickerStyle(.segmented)
            if criterion == .folder {
                HStack {Text(folder.isEmpty ? "尚未选择文件夹":folder).lineLimit(3).textSelection(.enabled);Spacer();Button("选择文件夹") {
                    let p=NSOpenPanel();p.canChooseFiles=false;p.canChooseDirectories=true;p.allowsMultipleSelection=false;p.title="选择批量勾选的文件夹";p.prompt="选择文件夹";p.message="选择需要匹配的文件夹，包含其子目录。"
                    if p.runModal() == .OK {folder=p.url?.path ?? ""}
                }}
                Text("勾选该文件夹及子文件夹内的候选副本。若两份都在其中，会自动保留一份。").font(.caption).foregroundStyle(.secondary)
            } else if criterion == .nameKeyword {
                Picker("操作",selection:$action){ForEach(BatchAction.allCases,id:\.self){Text($0.rawValue).tag($0)}}.pickerStyle(.segmented)
                TextField("输入关键词，例如：Remix，副本",text:$keywords)
                Toggle("必须包含全部关键词",isOn:$requireAllKeywords)
                Text("默认包含任一关键词即命中；使用逗号、分号或换行分隔。忽略大小写，在完整文件名（含扩展名）中查找，不检索文件夹路径。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if criterion == .size || criterion == .duration || criterion == .nameLength {
                Picker("规则",selection:$order) {ForEach(BatchOrder.allCases,id:\.self){item in
                    Text(criterion == .nameLength ? (item == .smaller ? "文件名较短的副本":item == .larger ? "文件名较长的副本":"指定字符数范围"):item.rawValue).tag(item)
                }}
                if order == .range {
                    HStack {TextField("最小值（留空为 0）",text:$minimum);Text("至");TextField("最大值（留空为不限）",text:$maximum);Text(criterion == .size ? "MiB":criterion == .nameLength ? "字符":"秒")}
                }
                Text(criterion == .nameLength ? "不含扩展名和文件夹路径，包含空格和标点。按可见字符计数（一个汉字或组合 emoji 算一个字符）；范围包含上下限。相同长度时按路径稳定选择。":criterion == .size ? "按实际文件大小勾选，不将大小等同于音质。":"按整首歌曲时长勾选；较短的版本可能存在剪辑，请试听。").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {Text("相似度至少");Slider(value:$similarity,in:0.72...1,step:0.01);Text("\(Int(similarity*100))%")}
                Text("对满足相似度的配对，优先勾选较小的副本；同大小时按路径稳定选择。高分并非完全相同的保证。").font(.caption).foregroundStyle(.secondary)
            }
            Text(feedback).font(.callout).foregroundStyle(.orange).frame(minHeight:44,alignment:.topLeading)
            Spacer()
            HStack {Button("清除全部勾选") {model.selection=[];feedback="已清除勾选。"};Spacer();Button("关闭") {dismiss()};Button("应用到勾选") {apply()}.buttonStyle(.borderedProminent)}
        }.padding(26)
        }.frame(width:760,height:450).onChange(of:criterion) {feedback=""}
    }
    func apply() {
        var request=BatchRequest();request.criterion=criterion;request.folder=folder;request.order=order;request.similarity=Float(similarity)
        if criterion == .folder && folder.isEmpty {feedback="请先选择文件夹。";return}
        if criterion == .nameKeyword {
            request.action=action
            request.nameKeywords=SelectionRules.parseKeywords(keywords)
            request.requireAllKeywords=requireAllKeywords
            if request.nameKeywords.isEmpty {feedback="请至少输入一个非空关键词。";return}
        }
        if criterion == .nameLength && order == .range {
            let lo=minimum.trimmingCharacters(in:.whitespaces),hi=maximum.trimmingCharacters(in:.whitespaces)
            guard let a=lo.isEmpty ? 0:Int(lo),let b=hi.isEmpty ? Int.max:Int(hi),a>=0,b>=a else {feedback="文件名长度请输入非负整数，最大值不能小于最小值。";return}
            request.minimum=Double(a);request.maximum=Double(b)
        }
        if (criterion == .size || criterion == .duration) && order == .range {
            let lo=minimum.trimmingCharacters(in:.whitespaces),hi=maximum.trimmingCharacters(in:.whitespaces)
            guard let a=lo.isEmpty ? 0:Double(lo),let b=hi.isEmpty ? Double.greatestFiniteMagnitude:Double(hi),a.isFinite,b.isFinite,a>=0,b>=a else {feedback="请输入有效范围：最小值不能小于 0，最大值不能小于最小值。";return}
            request.minimum=a;request.maximum=b
        }
        let previous=model.selection.count
        let result=SelectionRules.apply(request,matches:model.shown,existing:model.selection)
        model.selection=result.paths
        if criterion == .nameKeyword && action == .deselect {
            feedback="关键词命中 \(result.proposed) 份，已取消 \(previous-result.paths.count) 份勾选；当前勾选 \(result.paths.count) 份。未移动任何文件。";return
        }
        feedback="规则命中 \(result.proposed) 份；目前已勾选 \(result.paths.count) 份。为保留副本，保护了 \(result.protected) 份。请检查路径后再决定是否移到废纸篓。"
    }
}
struct MixerView:View {
    @ObservedObject var model:Model
    @ObservedObject var mixer:AudioMixer
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        ScrollView {
        VStack(alignment:.leading,spacing:15) {
            HStack {Text("同步对比试听").font(.title2.bold());Spacer();Button("关闭") {mixer.pause();dismiss()}}
            Text("2–3 首同时从同一设备时钟启动。拖动 A/B/C 滑块淡入淡出，或分别调节音量；混合总增益会归一化，避免叠加放大。").foregroundStyle(.secondary).font(.callout)
            ForEach(Array(mixer.songs.enumerated()),id:\.element.path) {i,song in
                VStack(alignment:.leading,spacing:5) {
                    HStack {Text("\(["A","B","C"][i])  \(song.name)").font(.headline).lineLimit(1);Spacer();Button("移除") {mixer.remove(song.path,matches:model.shown)}}
                    Text(song.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                    HStack {Text("音量").font(.caption);Slider(value:Binding(get:{Double(mixer.gains.indices.contains(i) ? mixer.gains[i]:0)},set:{mixer.setGain(i,Float($0))}),in:0...1);Text("\(Int((mixer.gains.indices.contains(i) ? mixer.gains[i]:0)*100))%").monospacedDigit().frame(width:45)}
                }.padding(10).background(StudioTheme.panel,in:RoundedRectangle(cornerRadius:6))
            }
            if mixer.songs.count<3 {
                Menu("添加第 \(mixer.songs.count+1) 首候选") {
                    ForEach(model.comparisonCandidates) {song in Button(song.name) {mixer.add(song,matches:model.shown)}}
                }.disabled(model.comparisonCandidates.isEmpty)
            }
            if mixer.songs.count>=2 {
                HStack {Text("A");Slider(value:Binding(get:{mixer.blend},set:{mixer.crossfade($0)}),in:0...Double(mixer.songs.count-1));Text(mixer.songs.count==3 ? "C":"B")}
                Text(mixer.songs.count==3 ? "左端只听 A，中间只听 B，右端只听 C；中间位置混合相邻两首。":"左端只听 A，右端只听 B；中间混合两首。播放持续运行，不会切断进度。").font(.caption).foregroundStyle(.secondary)
                HStack {Text(durationText(mixer.timeline)).monospacedDigit();Slider(value:Binding(get:{min(mixer.timeline,max(0.01,mixer.duration))},set:{mixer.seek($0)}),in:0...max(0.01,mixer.duration));Text(durationText(mixer.duration)).monospacedDigit()}
                HStack {
                    Button(mixer.isPlaying ? "暂停":"同步播放") {mixer.isPlaying ? mixer.pause():mixer.play()}.buttonStyle(.borderedProminent)
                    Button("停止") {mixer.stop()}
                    Toggle("按检测偏移自动对齐",isOn:Binding(get:{mixer.aligned},set:{mixer.aligned=$0;mixer.changeAlignment(model.shown)})).font(.caption)
                }
            }
            Text(mixer.message).foregroundStyle(.orange).font(.caption).frame(minHeight:30)
            Spacer(minLength:0)
        }.padding(24)
        }.frame(width:760,height:680).onDisappear{mixer.pause()}
    }
}


struct SelectedFilesView:View {
    @ObservedObject var model:Model
    @Environment(\.dismiss) private var dismiss
    @State private var page=0
    private var pages:Int{max(1,(model.selectedFiles.count+99)/100)}
    private var safePage:Int{min(page,pages-1)}
    private var rows:[SongPrint]{let start=min(safePage*100,model.selectedFiles.count);return Array(model.selectedFiles[start..<min(start+100,model.selectedFiles.count)])}
    var body:some View {
        VStack(alignment:.leading,spacing:14){
            HStack{Text("已勾选的文件").font(.title2.bold());Spacer();Button("关闭"){dismiss()}}
            Text("共 \(model.selectedFiles.count) 份 · \(sizeText(model.selectedBytes)) · 查看与取消勾选不会移动文件").font(.callout).foregroundStyle(.secondary)
            ScrollView{LazyVStack(alignment:.leading,spacing:12){ForEach(rows){song in
                VStack(alignment:.leading,spacing:6){
                    HStack{Text(song.name).font(.headline).textSelection(.enabled);Spacer();Button("取消勾选"){model.selection.remove(song.path)}}
                    Text(song.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack{Text("\(sizeText(song.size)) · \(durationText(song.duration))").font(.caption);Spacer();Button("定位文件"){model.reveal(song.path)}}
                }.padding(12).background(StudioTheme.panel,in:RoundedRectangle(cornerRadius:6))
            }}}.id(safePage)
            HStack{
                Button("上一页"){page=max(0,safePage-1)}.disabled(safePage==0)
                Text("第 \(safePage+1) / \(pages) 页").font(.caption)
                Button("下一页"){page=safePage+1}.disabled(safePage+1>=pages)
                Spacer();Button("清除全部勾选"){model.selection=[];page=0}
            }
        }.padding(24).frame(width:850,height:600)
    }
}
