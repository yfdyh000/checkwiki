#! /usr/bin/env perl

###########################################################################
##
##          FILE: check_901_standalone.pl
##
##         USAGE: ./check_901_standalone.pl [选项]
##
##   DESCRIPTION: 独立脚本，扫描维基百科XML dump文件，
##                找出901错误（reflist模板使用纯数字匿名参数）
##                并输出为可交换(JSON)和可阅读(TSV)格式
##
##                支持限量输出、分阶段增量写入、Toolforge Jobs 运行
##
##        AUTHOR: Based on checkwiki.pl error 901 logic
##       LICENCE: GPLv3
##
###########################################################################

use strict;
use warnings;
use feature 'unicode_strings';
use utf8;

use Getopt::Long qw(:config no_ignore_case gnu_compat);
use File::Basename;
use File::Path qw(make_path);
use File::Spec;
use POSIX qw(strftime);
#use MediaWiki::API;

# Windows 控制台 UTF-8 支持
if ($^O eq 'MSWin32') {
    eval {
        require Win32::Console;
        Win32::Console::OutputCP(65001);  # 设置控制台输出为 UTF-8
    };
    if ($@) {
        warn "无法加载 Win32::Console: $@";
    }
}

binmode( STDOUT, ':encoding(UTF-8)' );
binmode( STDERR, ':encoding(UTF-8)' );

##############################
##  全局变量
##############################

my $dump_dir    = '/public/dumps/public/zhwiki/2*';
my $output_dir  = '~/public_html/901';  # 默认输出目录
my $max_results = 100;    # 最大输出结果数，0表示不限制
my $verbose     = 0;
my $help        = 0;
my $toolforge   = 0;       # Toolforge Jobs 模式
my $incremental = 0;       # 增量写入模式（边扫描边输出）
my $dump_file_override = '';  # 直接指定dump文件路径
my $check_article = '';  # 指定要检查的特定条目
my $tests = 0;           # 测试模式

GetOptions(
    'dumpdir=s'    => \$dump_dir,
    'dumpfile=s'   => \$dump_file_override,
    'output=s'     => \$output_dir,
    'max-results=i'=> \$max_results,
    'incremental'  => \$incremental,
    'toolforge'    => \$toolforge,
    'verbose'      => \$verbose,
    'page=s'       => \$check_article,
    'tests'        => \$tests,
    'help'         => \$help,
) or die "参数错误，请使用 --help 查看用法\n";

# 解码命令行参数值为UTF-8（与 use utf8 配合，参考 checkwiki.pl）
utf8::decode($check_article)      if $check_article ne '';
utf8::decode($dump_dir)           if $dump_dir ne '';
utf8::decode($dump_file_override) if $dump_file_override ne '';
utf8::decode($output_dir)         if $output_dir ne '';

if ($help) {
    print <<"END_HELP";
用法: $0 [选项]

选项:
  --dumpdir=<path>     指定dump文件所在目录
                       默认: /public/dumps/public/zhwiki/2*
  --dumpfile=<path>    直接指定dump文件路径（覆盖--dumpdir的自动查找）
  --output=<path>      指定输出目录
                       默认: ~/public_html/901
                       本地运行时可设为 . (当前目录)
  --max-results=<N>    限制最大输出结果数（默认: 100，0=不限制）
  --incremental        增量写入模式，边扫描边输出结果，并继续上次的进度。仍需优化
  --toolforge          Toolforge模式：使用项目lib路径，适配K8s作业环境
  --page=<title>       指定要检查的特定条目（使用Live API）
  --tests              运行内置测试用例
  --verbose            显示详细处理信息
  --help               显示此帮助信息

输出文件:
  1. <output>/checkwiki_901_results.tsv    - TSV格式，便于阅读和电子表格打开
  2. <output>/checkwiki_901_summary.txt    - 摘要报告
  3. <output>/checkwiki_901_progress.log   - 进度日志（增量模式）

901错误说明:
  检测参考文献模板（reflist、註腳、注脚、參考資料、references等）
  中使用了纯数字匿名参数的情况。
  例如: {{reflist|3}} 应改为 {{reflist|colwidth=3}}
  这是因为纯数字匿名参数的语义不明确，可能被误解为列数或其他参数。

Toolforge Jobs 用法:
  # 方式1: 通过 toolforge jobs 运行
  toolforge jobs run cw-901-scan --command "/data/project/yfdyh-checkwiki/bin/check_901_standalone.pl --toolforge --incremental --max-results 100" --image perl5.40 --mem 4Gi --cpu=1000m
  终止方法: toolforge jobs delete cw-901-scan

  # 方式2: 通过 toolforgejobs.yaml 配置（见文件末尾注释）

  # 方式3: 手动 jsub
  jsub -N cw-901-scan /data/project/yfdyh-checkwiki/bin/check_901_standalone.pl --toolforge --incremental

单条目检查用法:
  # 使用Live API检查特定条目（不需要dump文件）
  ./check_901_standalone.pl --page="条目名"
  
  # 示例：检查"中华人民共和国"条目
  ./check_901_standalone.pl --page="中华人民共和国"

测试模式用法:
  # 运行内置测试用例
  ./check_901_standalone.pl --tests
END_HELP
    exit 0;
}

##############################
##  测试模式
##############################

if ($tests) {
    print "=== 测试模式 ===\n";
    my @test_cases = (
        { name => "无参数",       text => "{{reflist}}",            expect => 0 },
        { name => "空匿名参数",       text => "{{reflist|}}",           expect => 0 },
        { name => "命名参数2", text => "{{reflist|2=1}}",        expect => 0 },
        { name => "匿名参数=2", text => "{{reflist|2}}",          expect => 1 },
        { name => "匿名参数=3", text => "{{reflist|3}}",          expect => 1 },
        { name => "匿名参数=4", text => "{{reflist|4}}",          expect => 1 },
        { name => "其他命名参数",     text => "{{reflist|colwidth=3}}", expect => 0 },
        { name => "混合参数",     text => "{{reflist|refs=3|2}}",   expect => 1 },
        { name => "模板别名", text => "{{reflist|2}}",          expect => 1 },
        { name => "模板别名", text => "{{footnotessmall|2}}",          expect => 1 },
        { name => "模板别名", text => "{{参考文献|2}}",          expect => 1 },
        { name => "模板别名", text => "{{参考文献}}",          expect => 0 },
        { name => "模板别名", text => "{{參考資料|2}}",          expect => 1 },
        { name => "模板别名", text => "{{注脚|2}}",          expect => 1 },
        { name => "模板别名", text => "{{refs|2}}",          expect => 1 },
        { name => "模板别名在非模板名", text => "{{A|refs}}",          expect => 0 },
    );

    my $total = scalar(@test_cases);
    my $passed = 0;

    foreach my $test (@test_cases) {
        my @errors = check_901_errors('测试', $test->{text});
        my $result = scalar(@errors) > 0 ? 1 : 0;

        if ($result == $test->{expect}) {
            print "通过: $test->{name}\n";
            $passed++;
        } else {
            print "失败: $test->{name} (预期: " . ($test->{expect} ? "匹配" : "不匹配") .
                  ", 实际: " . ($result ? "匹配" : "不匹配") . ")\n";
        }
    }

    print "\n=== 测试结果 ===\n";
    print "总计: $total, 通过: $passed, 失败: " . ($total - $passed) . "\n";

    exit $total == $passed ? 0 : 1;
}

##############################
##  Toolforge 模式调整
##############################

if ($toolforge) {
    # 使用项目本地lib路径
    use lib '/data/project/yfdyh-checkwiki/perl/lib/perl5';
    use lib '/data/project/yfdyh-checkwiki/bin';

    $verbose = 1;  # Toolforge模式下默认显示进度
    print "[Toolforge模式] 启动\n";
}

##############################
##  查找dump文件
##############################

sub find_dump_file {
    my ($dir) = @_;

    # 与 checkwiki.pl 一致：优先使用非multistream文件
    # MediaWiki::DumpFile::Pages 可以直接处理单流 bz2 文件
    # multistream bz2 文件由多个独立bzip2流组成，IO::Uncompress无法正确处理
    my @patterns = (
        '*-pages-articles.xml.bz2',
        '*-pages-articles.xml',
        '*-pages-articles-multistream.xml.bz2',
        '*-pages-articles-multistream.xml',
    );

    # 收集所有匹配的文件，随后按时间或文件名中的日期排序，返回最新的一个
    my @candidates;

    # 在当前目录直接搜索
    for my $pattern (@patterns) {
        push @candidates, glob( File::Spec->catfile( $dir, $pattern ) );
    }

    # 递归搜索子目录（dump 目录结构可能是 .../zhwiki/20260501/zhwiki-20260501-pages-articles.xml.bz2）
    for my $pattern (@patterns) {
        push @candidates, glob( File::Spec->catfile( $dir, '*', $pattern ) );
    }

    return undef unless @candidates;

    # 如果文件名中包含日期（如 20260501），可以通过正则提取并比较；否则回退到文件修改时间
    my @sorted = sort {
        my ($a_date) = $a =~ /(\d{8})/;
        my ($b_date) = $b =~ /(\d{8})/;
        if ( $a_date && $b_date ) {
            $b_date <=> $a_date;    # 日期越大越新，降序
        } else {
            # 使用文件的修改时间作为后备比较
            ( stat($b) )[9] <=> ( stat($a) )[9];
        }
    } @candidates;

    return $sorted[0];
}

##############################
##  模板解析器
##############################

# 解析维基文本中的所有模板调用
# 返回数组，每个元素为: { name => 模板名, params => [{ name => 参数名, value => 参数值 }] }
sub parse_templates {
    my ($text) = @_;
    my @templates;

    return @templates unless $text =~ /\{\{/;

    # 使用与 checkwiki.pl get_templates_all 类似的逻辑
    # 先提取所有匹配的 {{ ... }} 对
    my @templates_all;
    my $test_text = $text;

    while ( $test_text =~ /\{\{/g ) {
        my $temp_text = substr( $test_text, pos($test_text) - 2 );
        my $brackets_begin = 1;
        my $brackets_end   = 0;
        my $temp_text_2    = q{};

        while ( $temp_text =~ /\}\}/g ) {
            $temp_text_2 = substr( $temp_text, 0, pos($temp_text) );
            $brackets_begin = ( $temp_text_2 =~ s/\{\{/\{\{/g );
            $brackets_end   = ( $temp_text_2 =~ s/\}\}/\}\}/g );
            last if ( $brackets_begin == $brackets_end
                     || abs( $brackets_begin - $brackets_end ) > 25 );
        }

        if ( $brackets_begin == $brackets_end ) {
            push( @templates_all, $temp_text_2 );
        }
    }

    # 解析每个模板
    for my $current_template (@templates_all) {
        # 清理
        $current_template =~ s/[
	]+/ /g;
        $current_template =~ s/^\{\{//;
        $current_template =~ s/\}\}$//;
        $current_template =~ s/^ //g;

        # 提取模板名和参数
        if ( index( $current_template, q{|} ) == -1 ) {
            next;  # 无参数的模板，如 {{reflist}}
        }

        my @template_split = split( /\|/, $current_template );
        next unless defined $template_split[0];

        # 获取模板名
        my $template_name = $template_split[0];
        $template_name =~ s/^ //g;
        $template_name =~ s/\s+$//;
        $template_name =~ tr/_/ / if index( $template_name, q{_} ) > -1;
        $template_name =~ tr/ / /s if index( $template_name, q{  } ) > -1;

        next if $template_name eq '';
        next if $template_name =~ /^\{/;   # 跳过 {{{参数}}}
        next if $template_name =~ /^#/;    # 跳过 parser functions
        next if $template_name =~ /^!/;    # 跳过 {{!}}

        shift(@template_split);  # 移除模板名

        # 重新组装参数（处理嵌套的 | ）
        my @template_part_array;
        my $template_part = q{};
        my $beginn_brackets       = 0;
        my $end_brackets          = 0;
        my $beginn_curly_brackets = 0;
        my $end_curly_brackets    = 0;

        for my $piece (@template_split) {
            $template_part .= $piece;

            $beginn_brackets       += ( $piece =~ tr/[/[/ );
            $end_brackets          += ( $piece =~ tr/]/]/ );
            $beginn_curly_brackets += ( $piece =~ tr/{/{/ );
            $end_curly_brackets    += ( $piece =~ tr/}/}/ );

            if (    $beginn_brackets == $end_brackets
                and $beginn_curly_brackets == $end_curly_brackets )
            {
                push( @template_part_array, $template_part );
                $template_part         = q{};
                $beginn_brackets       = 0;
                $end_brackets          = 0;
                $beginn_curly_brackets = 0;
                $end_curly_brackets    = 0;
            }
            else {
                $template_part .= q{|};
            }
        }

        # 解析每个参数
        my @params;
        my $template_part_without_attribut = 1;

        for my $part (@template_part_array) {
            my $attribut = q{};
            my $value    = q{};

            if ( index( $part, q{=} ) > -1 ) {
                my $pos_equal     = index( $part, q{=} );
                my $pos_lower     = index( $part, q{<} );
                my $pos_next_temp = index( $part, '{{' );
                my $pos_table     = index( $part, '{|' );
                my $pos_bracket   = index( $part, q{[} );

                my $equal_ok = 1;
                $equal_ok = 0 if ( $pos_lower > -1 and $pos_lower < $pos_equal );
                $equal_ok = 0 if ( $pos_next_temp > -1 and $pos_next_temp < $pos_equal );
                $equal_ok = 0 if ( $pos_table > -1 and $pos_table < $pos_equal );
                $equal_ok = 0 if ( $pos_bracket > -1 and $pos_bracket < $pos_equal );

                if ( $equal_ok == 1 ) {
                    $attribut = substr( $part, 0, index( $part, q{=} ) );
                    $value    = substr( $part, index( $part, q{=} ) + 1 );
                }
                else {
                    $attribut = $template_part_without_attribut;
                    $template_part_without_attribut++;
                    $value = $part;
                }
            }
            else {
                $attribut = $template_part_without_attribut;
                $template_part_without_attribut++;
                $value = $part;
            }

            $attribut =~ s/^\s+//;  $attribut =~ s/\s+$//;
            $value    =~ s/^\s+//;  $value    =~ s/\s+$//;

            push @params, {
                name  => $attribut,
                value => $value,
            };
        }

        push @templates, {
            name   => $template_name,
            params => \@params,
        };
    }

    return @templates;
}

##############################
##  901错误检查
##############################

sub check_901_errors {
    # 目标模板列表（小写）
    my %target_templates = map { lc($_) => 1 } (
        'footnotessmall', '註腳', '注脚', '參考資料',
        'reflist', 'references', 'refs',
        '参考列表', '脚注', '参考文献'
    );

    my ($title, $text) = @_;

    # $title 参数没有用？？
    my @errors;

    my @templates = parse_templates($text);

    for my $tmpl (@templates) {
        my $tmpl_name_lc = lc($tmpl->{name});

        # 检查是否是目标模板
        next unless exists $target_templates{$tmpl_name_lc};

        # 检查参数
        for my $param (@{$tmpl->{params}}) {
            my $param_name  = $param->{name};
            my $param_value = $param->{value};

            # 只检查第一个匿名参数（参数名为 '1'）
            next unless $param_name eq '1';

            # 检查值是否为纯数字
            next unless $param_value =~ /^\d+$/;

            # 报告901错误：reflist模板使用了纯数字匿名参数
            # 例如: {{reflist|3}} 应改为 {{reflist|colwidth=3}}
            my $error_text = '{{' . $tmpl->{name} . '|' . $param_value . '}}';
            $error_text = substr($error_text, 0, 80);  # 限制长度

            push @errors, {
                template     => $tmpl->{name},
                param_name   => $param_name,
                param_value  => $param_value,
                error_text   => $error_text,
            };
        }
    }

    return @errors;
}

##############################
##  增量写入辅助函数
##############################

my $tsv_fh;     # TSV文件句柄（增量模式）
my $progress_fh; # 进度日志句柄
my $state_file;  # 状态文件路径

# 读取上次运行的状态
sub read_last_state {
    my ($out_dir) = @_;
    my $state_file = File::Spec->catfile($out_dir, 'checkwiki_901_state.txt');
    
    my %state = (
        last_article => '',
        error_count => 0,
        artcount => 0
    );
    
    if (-e $state_file) {
        open(my $sfh, '<:encoding(UTF-8)', $state_file) or die "无法读取状态文件 $state_file: $!\n";
        while (<$sfh>) {
            chomp;
            if (/^last_article=(.*)$/) {
                $state{last_article} = $1;
            } elsif (/^error_count=(\d+)$/) {
                $state{error_count} = $1;
            } elsif (/^artcount=(\d+)$/) {
                $state{artcount} = $1;
            }
        }
        close($sfh);
        print "[增量模式] 从上次运行恢复: 已处理 $state{artcount} 个条目, 发现 $state{error_count} 个错误\n";
        print "[增量模式] 上次最后处理的条目: $state{last_article}\n";
    }
    
    return %state;
}

# 保存当前状态
sub save_state {
    my ($out_dir, $last_article, $error_count, $artcount) = @_;
    my $state_file = File::Spec->catfile($out_dir, 'checkwiki_901_state.txt');
    # TODO: 确保该文件始终完整
    
    open(my $sfh, '>:encoding(UTF-8)', $state_file) or die "无法写入状态文件 $state_file: $!\n";
    print $sfh "last_article=$last_article\n";
    print $sfh "error_count=$error_count\n";
    print $sfh "artcount=$artcount\n";
    close($sfh);
}

sub open_incremental_files {
    my ($out_dir) = @_;

    # TSV - 追加模式，保留原有内容
    my $tsv_file = File::Spec->catfile($out_dir, 'checkwiki_901_results.tsv');
    my $tsv_exists = -e $tsv_file;
    
    if ($tsv_exists) {
        open($tsv_fh, '>>:encoding(UTF-8)', $tsv_file) or die "无法追加写入 $tsv_file: $!\n";
        print "[增量模式] 追加模式写入TSV文件: $tsv_file\n";
    } else {
        open($tsv_fh, '>:encoding(UTF-8)', $tsv_file) or die "无法写入 $tsv_file: $!\n";
        print $tsv_fh "序号\t条目名\t模板名\t参数名\t参数值\t错误文本\n";
    }

    # 进度日志 - 追加模式
    my $progress_file = File::Spec->catfile($out_dir, 'checkwiki_901_progress.log');
    open($progress_fh, '>>:encoding(UTF-8)', $progress_file) or die "无法追加写入 $progress_file: $!\n";

    return $tsv_file;
}

sub write_incremental_result {
    my ($idx, $result) = @_;

    # TSV
    my $safe_title = $result->{title};
    $safe_title =~ s/\t/ /g;
    $safe_title =~ s/\n/ /g;
    my $safe_error = $result->{error_text};
    $safe_error =~ s/\t/ /g;
    $safe_error =~ s/\n/ /g;
    printf $tsv_fh "%d\t%s\t%s\t%s\t%s\t%s\n",
        $idx,
        $safe_title,
        $result->{template},
        $result->{param_name},
        $result->{param_value},
        $safe_error;

    # 定期刷新
    if ($idx % 100 == 0) {
        $tsv_fh->flush();
    }
}

sub close_incremental_files {
    close($tsv_fh);
    close($progress_fh);
}

sub write_progress {
    my ($artcount, $error_count, $title) = @_;
    my $ts = strftime("%Y-%m-%d %H:%M:%S", localtime());
    printf $progress_fh "[%s] 已处理 %d 条目, 发现 %d 错误, 当前: %s\n",
        $ts, $artcount, $error_count, $title;
    $progress_fh->flush();
}



##############################
##  处理单个条目
##############################

sub process_article {
    my ($title, $text) = @_;

    # 跳过重定向页面
    my $lc_text = lc($text);
    if (index($lc_text, '#redirect') > -1) {
        return ();
    }

    my @errors = check_901_errors($title, $text);

    return @errors;
}

##############################
##  使用Live API获取条目内容
##############################

sub get_article_from_api {
# TODO: use MediaWiki::API
    my ($title, $wiki) = @_;

    # 默认使用中文维基百科
    $wiki = 'zh.wikipedia.org' unless defined $wiki;

    # 创建 MediaWiki::API 对象
    my $mw = MediaWiki::API->new({
        max_lag         => 5,
        max_lag_delay   => 5,
        max_lag_retries => 5,
        retries         => 2,
        retry_delay     => 10,
        use_http_get => 1,
        api_url      => "https://$wiki/w/api.php"
    });

    $mw->{ua}->agent("Checkwiki-yfdyh/1.0");

    # 构建API请求参数
    my $hash = {
        action  => 'query',
        titles  => $title,
        prop    => 'revisions',
        rvprop  => 'content',
        rvslots => 'main'
    };

    # 发送API请求
    my $res = $mw->api($hash);
    unless ($res) {
        warn "API请求失败: " . $mw->{error}->{code} . ": " . $mw->{error}->{details} . "\n";
        return undef;
    }

    # 获取页面数据
    my ( $id, $data ) = %{ $res->{query}->{pages} };

    # 检查页面是否存在
    if ($id == -1) {
        print "警告: 条目 $title 不存在\n";
        return undef;
    }

    # 返回页面内容
    return $data->{revisions}[0]->{slots}->{main}->{'*'};
}

##############################
##  主程序
##############################

print "=" x 60, "\n";
print "CheckWiki 901 错误独立扫描工具\n";
print "=" x 60, "\n\n";

print "配置:\n";
print "  Dump目录:     $dump_dir\n";
print "  输出目录:     $output_dir\n";
print "  最大结果数:   " . ($max_results > 0 ? $max_results : "不限制") . "\n";
print "  增量写入:     " . ($incremental ? "是" : "否") . "\n";
print "  Toolforge:    " . ($toolforge ? "是" : "否") . "\n\n";

# 检查是否使用Live API模式
my $use_api = 0;
if ($check_article ne '') {
    $use_api = 1;
    print "[Live API模式] 将检查指定条目: $check_article\n\n";
}

# 查找dump文件
my $dump_file;
if (!$use_api) {
    if ($dump_file_override ne '') {
        $dump_file = $dump_file_override;
        print "使用指定的dump文件: $dump_file\n";
    } else {
        print "正在查找dump文件...\n";
        $dump_file = find_dump_file($dump_dir);
        if (!$dump_file) {
            die "错误: 在 $dump_dir 中未找到dump文件\n"
              . "请确保目录中包含 *-pages-articles.xml.bz2 或类似文件\n";
        }
        print "找到dump文件: $dump_file\n";
    }
    print "\n";
}

# 1. 展开路径中的 ~ 符号，因为 Perl 不会自动解析它
$output_dir =~ s/^~/$ENV{HOME}/;

# 2. 若目录不存在则递归创建
unless (-d $output_dir) {
    make_path($output_dir) or die "Cannot create directory $output_dir: $!\n";
}

# 确保输出目录存在且可写
if (!-d $output_dir) {
    eval { mkdir $output_dir };
    if (!-d $output_dir) {
        # 无法创建目录，回退到可写位置
        my $fallback = File::Spec->catfile($ENV{HOME} // '/tmp', 'checkwiki_901_output');
        warn "Warning: Cannot create output dir $output_dir: $!, falling back to $fallback\n";
        $output_dir = $fallback;
        mkdir $output_dir unless -d $output_dir;
    }
}
if (!-w $output_dir) {
    # 目录存在但不可写，回退
    my $fallback = File::Spec->catfile($ENV{HOME} // '/tmp', 'checkwiki_901_output');
    warn "Warning: Output dir $output_dir is not writable, falling back to $fallback\n";
    $output_dir = $fallback;
    mkdir $output_dir unless -d $output_dir;
}

# 检查是否安装了 MediaWiki::DumpFile::Pages
my $use_mediawiki_dumpfile = 0;
eval {
    require MediaWiki::DumpFile::Pages;
    MediaWiki::DumpFile::Pages->import();
    $use_mediawiki_dumpfile = 1;
};
if ($@) {
    print "警告: 未安装 MediaWiki::DumpFile::Pages 模块\n";
    print "将尝试使用纯文本XML解析方式\n\n";
}

# 结果存储
my @all_results;  # 所有错误结果（非增量模式使用）
my $artcount    = 0;
my $error_count = 0;
my $time_start  = time();
my $reached_limit = 0;
my $skip_until_title = '';  # 跳过到此条目之前的所有条目
my $last_processed_title = '';  # 记录最后一个处理的条目标题

# 增量模式文件句柄
my $tsv_file_path;

if ($incremental) {
    # 读取上次状态
    my %last_state = read_last_state($output_dir);
    $artcount = $last_state{artcount};
    $error_count = $last_state{error_count};
    $skip_until_title = $last_state{last_article};
    
    $tsv_file_path = open_incremental_files($output_dir);
}

########################################
# 扫描dump文件或使用Live API
########################################

if ($use_api) {
    ########################################
    # Live API模式：检查指定条目
    ########################################
    print "正在从Live API获取条目内容...\n";

    my $text = get_article_from_api($check_article);

    if (defined $text) {
        my @errors = check_901_errors($check_article, $text);

        # 直接在控制台输出匹配结果（不写文件）
        if (@errors) {
            print "\n在条目 [[$check_article]] 中发现 " . scalar(@errors) . " 个901错误:\n";
            for my $i (0 .. $#errors) {
                my $err = $errors[$i];
                printf "  %d. 模板: %s, 参数: %s=%s\n", $i+1, $err->{template}, $err->{param_name}, $err->{param_value};
                printf "     错误文本: %s\n", $err->{error_text};
            }
        } else {
            print "\n条目 [[$check_article]] 中未发现901错误\n";
        }
    }

    # Live模式直接退出，不写入文件
    exit(0);
} elsif ($use_mediawiki_dumpfile) {
    ########################################
    # 方式1: 使用 MediaWiki::DumpFile::Pages
    # 与 checkwiki.pl scan_pages() 一致的实现方式
    ########################################
    print "使用 MediaWiki::DumpFile::Pages 解析dump文件...\n\n";

    my $pages = MediaWiki::DumpFile::Pages->new($dump_file);

    while (my $page = $pages->next) {
        next if ($page->namespace ne '0');  # 只处理条目命名空间

        my $title = $page->title;
        next if $title eq '';

        # 增量模式：跳过已处理的条目
        if ($incremental && $skip_until_title ne '') {
            if ($title ne $skip_until_title) {
                next;
            } else {
                # 找到上次最后处理的条目，跳过它，开始处理下一个
                $skip_until_title = '';
                next;
            }
        }

        my $text = $page->revision->text;
        next unless defined $text;

        # 跳过重定向页面
        my $lc_text = lc($text);
        if (index($lc_text, '#redirect') > -1) {
            next;
        }
        $artcount++;

        if ($artcount % 500 == 0) {
            printf("  已处理 %d 个条目, 发现 %d 个901错误\n", $artcount, $error_count);
            if ($incremental) {
                write_progress($artcount, $error_count, $title);
            }
        }

        my @errors = process_article($title, $text);
        
        # 记录最后一个处理的条目
        $last_processed_title = $title;

        if (@errors) {
            for my $err (@errors) {
                $error_count++;

                my $result = {
                    title       => $title,
                    template    => $err->{template},
                    param_name  => $err->{param_name},
                    param_value => $err->{param_value},
                    error_text  => $err->{error_text},
                };

                if ($incremental) {
                    write_incremental_result($error_count, $result);
                } else {
                    push @all_results, $result;
                }

                # 检查是否达到结果上限
                if ($max_results > 0 && $error_count >= $max_results) {
                    $reached_limit = 1;
                    printf("\n已达到最大结果数限制 (%d)，停止扫描\n", $max_results);
                    last;
                }
            }
        }
        
        # 增量模式：定期保存状态
        if ($incremental && $artcount % 100 == 0) {
            save_state($output_dir, $title, $error_count, $artcount);
        }

        last if $reached_limit;
    }
} else {
    ########################################
    # 方式2: 纯文本XML解析（无需额外模块）
    ########################################
    print "使用纯文本XML解析模式...\n";

    my $fh;
    my $is_bz2 = ($dump_file =~ /\.bz2$/);

    if ($is_bz2) {
        print "检测到bz2压缩文件，尝试通过管道解压...\n";
        open($fh, '-|:encoding(UTF-8)', "bzcat " . quotemeta($dump_file))
            or die "无法打开管道: $!\n";
    } else {
        open($fh, '<:encoding(UTF-8)', $dump_file)
            or die "无法打开文件: $dump_file: $!\n";
    }
    print "\n";

    my $in_page  = 0;
    my $in_title = 0;
    my $in_text  = 0;
    my $in_ns    = 0;
    my $current_title = '';
    my $current_text  = '';
    my $current_ns    = -1;

    while (<$fh>) {
        if (/<page>/) {
            $in_page = 1;
            $current_title = '';
            $current_text  = '';
            $current_ns    = -1;
        } elsif (/<\/page>/) {
            $in_page = 0;

            # 只处理条目命名空间
            if ($current_ns == 0 && $current_title ne '' && $current_text ne '') {
                # 增量模式：跳过已处理的条目
                if ($incremental && $skip_until_title ne '') {
                    if ($current_title ne $skip_until_title) {
                        $artcount++;
                        next;
                    } else {
                        # 找到上次最后处理的条目，跳过它，开始处理下一个
                        $artcount++;
                        $skip_until_title = '';
                        next;
                    }
                }
                
                # 跳过重定向页面
                my $lc_text = lc($current_text);
                if (index($lc_text, '#redirect') > -1) {
                    next;
                }
                $artcount++;

                if ($artcount % 500 == 0) {
                    printf("  已处理 %d 个条目, 发现 %d 个901错误\n", $artcount, $error_count);
                    if ($incremental) {
                        write_progress($artcount, $error_count, $current_title);
                    }
                }

                my @errors = process_article($current_title, $current_text);
                
                # 记录最后一个处理的条目
                $last_processed_title = $current_title;

                if (@errors) {
                    for my $err (@errors) {
                        $error_count++;

                        my $result = {
                            title       => $current_title,
                            template    => $err->{template},
                            param_name  => $err->{param_name},
                            param_value => $err->{param_value},
                            error_text  => $err->{error_text},
                        };

                        if ($incremental) {
                            write_incremental_result($error_count, $result);
                        } else {
                            push @all_results, $result;
                        }

                        # 检查是否达到结果上限
                        if ($max_results > 0 && $error_count >= $max_results) {
                            $reached_limit = 1;
                            printf("\n已达到最大结果数限制 (%d)，停止扫描\n", $max_results);
                            last;
                        }
                    }
                }
                
                # 增量模式：定期保存状态
                if ($incremental && $artcount % 100 == 0) {
                    save_state($output_dir, $current_title, $error_count, $artcount);
                }
            }

            last if $reached_limit;
        } elsif ($in_page && !$in_text) {
            if (/<title>(.*?)<\/title>/) {
                $current_title = $1;
            } elsif (/<ns>(\d+)<\/ns>/) {
                $current_ns = $1;
            } elsif (/<text[^>]*>/) {
                # text标签可能跨多行
                $in_text = 1;
                $current_text = $_;
                $current_text =~ s/.*<text[^>]*>//;
                # 检查是否在同一行关闭
                if ($current_text =~ s/<\/text>.*//s) {
                    $in_text = 0;
                }
            }
        }

        if ($in_text) {
            if (/<\/text>/) {
                $in_text = 0;
                s/<\/text>.*//s;
                $current_text .= $_;
            } else {
                $current_text .= $_;
            }
        }
    }

    close($fh);
}

my $time_end = time();
my $elapsed  = $time_end - $time_start;

printf("\n扫描完成! 共处理 %d 个条目, 发现 %d 个901错误, 耗时 %d 秒\n",
    $artcount, $error_count, $elapsed);

if ($reached_limit) {
    printf("注意: 已达到最大结果数限制 (%d)，实际错误可能更多\n", $max_results);
}

##############################
##  输出结果
##############################

if ($incremental) {
    # 增量模式：保存最终状态并关闭文件
    # 保存最后一个处理过的条目状态
    if ($artcount > 0) {
        save_state($output_dir, $last_processed_title, $error_count, $artcount);
    }
    close_incremental_files();

} else {
    # 非增量模式：一次性写入TSV文件
    my $tsv_file = File::Spec->catfile($output_dir, 'checkwiki_901_results.tsv');
    print "正在写入TSV结果: $tsv_file\n";

    open(my $tsv_fh_out, '>:encoding(UTF-8)', $tsv_file) or die "无法写入 $tsv_file: $!\n";
    print $tsv_fh_out "序号\t条目名\t模板名\t参数名\t参数值\t错误文本\n";
    my $idx = 0;
    for my $r (@all_results) {
        $idx++;
        my $safe_title = $r->{title};
        $safe_title =~ s/\t/ /g;
        $safe_title =~ s/\n/ /g;
        my $safe_error = $r->{error_text};
        $safe_error =~ s/\t/ /g;
        $safe_error =~ s/\n/ /g;
        printf $tsv_fh_out "%d\t%s\t%s\t%s\t%s\t%s\n",
            $idx,
            $safe_title,
            $r->{template},
            $r->{param_name},
            $r->{param_value},
            $safe_error;
    }
    close($tsv_fh_out);
}

# 3. 输出摘要报告（总是最后写入）
my $summary_file = File::Spec->catfile($output_dir, 'checkwiki_901_summary.txt');
print "正在写入摘要报告: $summary_file\n";

open(my $sum_fh, '>:encoding(UTF-8)', $summary_file) or die "无法写入 $summary_file: $!\n";
print $sum_fh "=" x 60, "\n";
print $sum_fh "CheckWiki 901 错误扫描摘要报告\n";
print $sum_fh "=" x 60, "\n\n";
print $sum_fh "扫描时间:        " . strftime("%Y-%m-%d %H:%M:%S", localtime($time_start)) . "\n";
print $sum_fh "Dump目录:        $dump_dir\n";
print $sum_fh "Dump文件:        $dump_file\n";
print $sum_fh "扫描条目数:      $artcount\n";
print $sum_fh "发现901错误数:   $error_count\n";
print $sum_fh "耗时:            $elapsed 秒\n";
print $sum_fh "最大结果限制:    " . ($max_results > 0 ? $max_results : "无限制") . "\n";
print $sum_fh "达到限制:        " . ($reached_limit ? "是" : "否") . "\n";
print $sum_fh "增量写入模式:    " . ($incremental ? "是" : "否") . "\n\n";

print $sum_fh "-" x 60, "\n";
print $sum_fh "901错误说明:\n";
print $sum_fh "  检测参考文献模板（reflist、註腳、注脚、參考資料、references等）\n";
print $sum_fh "  中使用了纯数字匿名参数的情况。\n";
print $sum_fh "  例如: {{reflist|3}} 应改为 {{reflist|colwidth=3}}\n";
print $sum_fh "-" x 60, "\n\n";

# 按模板统计
# 需要读取结果来统计
my @results_for_summary;
if ($incremental) {
    # 从TSV文件读取
    my $tsv_file = File::Spec->catfile($output_dir, 'checkwiki_901_results.tsv');
    open(my $tfh, '<:encoding(UTF-8)', $tsv_file) or die "无法读取 $tsv_file: $!\n";
    my $header = <$tfh>;  # 跳过表头
    while (<$tfh>) {
        chomp;
        my @fields = split /\t/;
        push @results_for_summary, { template => $fields[2] } if @fields >= 3;
    }
    close($tfh);
} else {
    @results_for_summary = @all_results;
}

my %template_stats;
for my $r (@results_for_summary) {
    $template_stats{$r->{template}}++;
}

print $sum_fh "按模板统计:\n";
for my $t (sort { $template_stats{$b} <=> $template_stats{$a} } keys %template_stats) {
    printf $sum_fh "  %-20s %d 次\n", $t, $template_stats{$t};
}
print $sum_fh "\n";

# 列出前50个错误
print $sum_fh "-" x 60, "\n";
print $sum_fh "前50个错误详情:\n";
print $sum_fh "-" x 60, "\n\n";

my $show_count = scalar(@results_for_summary) > 50 ? 50 : scalar(@results_for_summary);
if ($incremental) {
    # 从TSV读取前50条
    my $tsv_file = File::Spec->catfile($output_dir, 'checkwiki_901_results.tsv');
    open(my $tfh, '<:encoding(UTF-8)', $tsv_file) or die "无法读取 $tsv_file: $!\n";
    my $header = <$tfh>;
    my $line_num = 0;
    while (<$tfh>) {
        last if $line_num >= 50;
        chomp;
        my @fields = split /\t/;
        next unless @fields >= 6;
        $line_num++;
        printf $sum_fh "%d. [[%s]]\n", $fields[0], $fields[1];
        printf $sum_fh "   模板: %s | 参数: %s=%s\n", $fields[2], $fields[3], $fields[4];
        printf $sum_fh "   错误文本: %s\n\n", $fields[5];
    }
    close($tfh);
} else {
    for my $i (0 .. $show_count - 1) {
        my $r = $all_results[$i];
        printf $sum_fh "%d. [[%s]]\n", $i + 1, $r->{title};
        printf $sum_fh "   模板: %s | 参数: %s=%s\n", $r->{template}, $r->{param_name}, $r->{param_value};
        printf $sum_fh "   错误文本: %s\n\n", $r->{error_text};
    }
}

if ($error_count > 50) {
    printf $sum_fh "... 还有 %d 个错误，请查看JSON或TSV文件获取完整列表\n",
        $error_count - 50;
}

close($sum_fh);


##############################
##  打包结果为 tar.gz
##############################
my $timestamp = strftime("%Y%m%d_%H%M%S", localtime($time_start));
my $tar_file = File::Spec->catfile($output_dir, "checkwiki_901_results_${timestamp}.tar.gz");

# 使用系统命令打包指定的结果文件
my @files_to_tar = (
    File::Spec->catfile($output_dir, 'checkwiki_901_results.tsv'),
    File::Spec->catfile($output_dir, 'checkwiki_901_summary.txt'),
);
# 增量模式包含日志文件
if ($incremental) {
    push @files_to_tar, File::Spec->catfile($output_dir, 'checkwiki_901_progress.log');
}

# 执行打包（使用 -C 切换目录，避免在压缩包内包含绝对路径）
my $tar_cmd = sprintf("tar czf %s -C %s %s",
    quotemeta($tar_file),
    quotemeta($output_dir),
    join(' ', map { quotemeta(basename($_)) } @files_to_tar)
);

print "正在打包结果文件: $tar_file\n";
system($tar_cmd) == 0
    or warn "警告: 打包 tar.gz 文件失败: $!\n";

print "\n输出文件:\n";
print "  TSV:   " . File::Spec->catfile($output_dir, 'checkwiki_901_results.tsv') . "   (电子表格/阅读格式)\n";
print "  摘要:  $summary_file (摘要报告)\n";
if ($incremental) {
    print "  日志:  " . File::Spec->catfile($output_dir, 'checkwiki_901_progress.log') . " (进度日志)\n";
}
print "\n完成!\n";

###########################################################################
##  Toolforge Jobs 配置参考
###########################################################################
##
## 在 toolforgejobs.yaml 中添加以下条目:
##
## - name: cw-901-scan
##   command: /data/project/yfdyh-checkwiki/bin/check_901_standalone.pl --toolforge --incremental --max-results 100
##   image: perl5.40
##   schedule: "0 2 1 * *"    # 每月1日凌晨2点运行
##   emails: none
##   cpu: 250m
##   mem: 2Gi
##
## 或通过命令行手动运行:
##
##   toolforge jobs run cw-901-scan \
##     --command "/data/project/yfdyh-checkwiki/bin/check_901_standalone.pl --toolforge --incremental --max-results 100" \
##     --image perl5.40
##
## 查看作业状态:
##   toolforge jobs list
##
## 查看日志:
##   cat /data/project/yfdyh-checkwiki/var/901/checkwiki_901_progress.log
##
###########################################################################
