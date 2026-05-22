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

  describe "STI" do
    describe "child without its own Setup (Article < Post)" do
      it "is readonly by default" do
        article = PostService.create_article("seed")
        expect { article.update!(title: "x") }.to raise_error(ActiveRecord::ReadOnlyRecord)
      end

      it "can be written from a service that includes Post::Writable" do
        article = PostService.create_article("seed")
        expect { PostService.update_article(article, "new") }.not_to raise_error
        expect(article.reload.title).to eq("new")
      end
    end

    describe "child with its own Setup (PrivateNote < Post)" do
      it "is readonly by default" do
        note = PostService.create_private_note("seed")
        expect { note.update!(title: "x") }.to raise_error(ActiveRecord::ReadOnlyRecord)
      end

      it "can be written from a service that includes Post::Writable (parent), via superclass walk" do
        note = PostService.create_private_note("seed")
        expect { PostService.update_private_note(note, "new") }.not_to raise_error
        expect(note.reload.title).to eq("new")
      end

      it "can be written from a service that includes PrivateNote::Writable" do
        note = PrivateNoteService.create("seed")
        expect { PrivateNoteService.update_title(note, "new") }.not_to raise_error
        expect(note.reload.title).to eq("new")
      end

      it "PrivateNote::Writable does not retroactively unlock Post (parent)" do
        post = PostService.create(title: "seed")
        expect { PrivateNoteService.try_update_post(post, "x") }
          .to raise_error(ActiveRecord::ReadOnlyRecord)
      end

      it "PrivateNote::Writable does not unlock Article (sibling)" do
        article = PostService.create_article("seed")
        expect { PrivateNoteService.try_update_article(article, "x") }
          .to raise_error(ActiveRecord::ReadOnlyRecord)
      end
    end
  end
end
