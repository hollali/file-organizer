class Organize < Formula
  desc "Sort files and folders into category folders with undoable moves"
  homepage "https://github.com/hollali/file-organizer"
  url "https://github.com/hollali/file-organizer/releases/download/vX.Y.Z/organize-vX.Y.Z.tar.gz"
  sha256 "REPLACE_WITH_RELEASE_SHA256"
  license "MIT"

  depends_on "bash"

  def install
    bin.install "organize.sh" => "organize"
    man1.install "man/organize.1"
    bash_completion.install "completions/organize.bash" => "organize"
    zsh_completion.install "completions/_organize"
    fish_completion.install "completions/organize.fish"
  end

  test do
    assert_match "organize.sh", shell_output("#{bin}/organize --version")
  end
end
