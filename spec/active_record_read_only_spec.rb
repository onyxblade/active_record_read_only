# frozen_string_literal: true

RSpec.describe ActiveRecordReadOnly do
  it "has a version number" do
    expect(ActiveRecordReadOnly::VERSION).not_to be nil
  end

  describe "readonly enforcement" do
    let(:post) { PostService.create(title: "seed") }

    it "blocks update! from a file that did not `include` Writable" do
      expect { post.update!(title: "x") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "blocks destroy! from a file that did not `include` Writable" do
      expect { post.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "blocks Post.create! from a file that did not `include` Writable" do
      expect { Post.create!(title: "x") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "allows update! from inside a file that `include` Writable" do
      expect { PostService.update_title(post, "new") }.not_to raise_error
      expect(post.reload.title).to eq("new")
    end

    it "allows destroy! from inside a file that `include` Writable" do
      expect { PostService.destroy(post) }.not_to raise_error
      expect(Post.exists?(post.id)).to be(false)
    end

    it "still allows when the service delegates through an unregistered helper (service frame remains on the stack)" do
      expect { PostService.update_via_helper(post, "via helper") }.not_to raise_error
      expect(post.reload.title).to eq("via helper")
    end
  end

  describe "cross-class isolation" do
    let(:post) { PostService.create(title: "seed") }
    let(:comment) { CommentService.create("seed comment") }

    it "PostService cannot write Comment (only Post::Writable was included)" do
      expect { PostService.try_update_comment(comment, "hacked") }
        .to raise_error(ActiveRecord::ReadOnlyRecord)
      expect(comment.reload.body).to eq("seed comment")
    end

    it "CommentService cannot write Post (only Comment::Writable was included)" do
      expect { CommentService.try_update_post(post, "hacked") }
        .to raise_error(ActiveRecord::ReadOnlyRecord)
      expect(post.reload.title).to eq("seed")
    end

    it "CommentService can still write Comment normally" do
      expect { CommentService.update_body(comment, "edited") }.not_to raise_error
      expect(comment.reload.body).to eq("edited")
    end

    it "a service that includes both can write both" do
      expect { BothService.update_post(post, "p2") }.not_to raise_error
      expect { BothService.update_comment(comment, "c2") }.not_to raise_error
      expect(post.reload.title).to eq("p2")
      expect(comment.reload.body).to eq("c2")
    end
  end
end
